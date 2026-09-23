#!/usr/bin/env bash
# PressGarden self-update engine. Replaces only repository-managed program files.
# Private configuration and runtime state are intentionally outside the managed set.
set -uo pipefail

PRESSGARDEN_DIR="${PRESSGARDEN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PRESSGARDEN_UPDATE_REPO="${PRESSGARDEN_REPO:-marketania/PressGarden}"
PRESSGARDEN_UPDATE_REF="${PRESSGARDEN_REF:-main}"

# Program paths owned by the PressGarden distribution. Never add config/config,
# var/, or .pressgarden-portable here: those are private/local runtime state.
_PRESSGARDEN_UPDATE_MANAGED=(
  .github .gitignore CHANGELOG.md CONTRIBUTING.md LICENSE README.md SECURITY.md VERSION PRODUCT PROVENANCE.md
  checks docs lib tests
  install.sh uninstall.sh pressgarden
)

_pg_update_tmpf() {
  mktemp "${TMPDIR:-/tmp}/pressgarden-update.XXXXXX" 2>/dev/null
}

_pg_update_fetch_archive() {
  local archive="$1" branch_url tag_url
  if [ -n "${PRESSGARDEN_UPDATE_ARCHIVE:-}" ]; then
    [ -r "$PRESSGARDEN_UPDATE_ARCHIVE" ] || { printf 'Update archive is not readable: %s\n' "$PRESSGARDEN_UPDATE_ARCHIVE" >&2; return 2; }
    cp "$PRESSGARDEN_UPDATE_ARCHIVE" "$archive" || return 2
    return 0
  fi

  branch_url="https://github.com/$PRESSGARDEN_UPDATE_REPO/archive/refs/heads/$PRESSGARDEN_UPDATE_REF.tar.gz"
  tag_url="https://github.com/$PRESSGARDEN_UPDATE_REPO/archive/refs/tags/$PRESSGARDEN_UPDATE_REF.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto "=https" --proto-redir "=https" --connect-timeout 15 --max-time 120 --max-filesize 33554432 "$branch_url" -o "$archive" 2>/dev/null || curl -fsSL --proto "=https" --proto-redir "=https" --connect-timeout 15 --max-time 120 --max-filesize 33554432 "$tag_url" -o "$archive" 2>/dev/null || {
      printf 'Could not download PressGarden update for ref %s.\n' "$PRESSGARDEN_UPDATE_REF" >&2
      return 2
    }
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only --timeout=30 --tries=2 -qO "$archive" "$branch_url" 2>/dev/null || wget --https-only --timeout=30 --tries=2 -qO "$archive" "$tag_url" 2>/dev/null || {
      printf 'Could not download PressGarden update for ref %s.\n' "$PRESSGARDEN_UPDATE_REF" >&2
      return 2
    }
  else
    printf 'PressGarden update requires curl or wget.\n' >&2
    return 2
  fi
}

_pg_update_validate_source() {
  local src="$1" list f version
  for f in checks lib tests config; do
    [ -d "$src/$f" ] && [ ! -L "$src/$f" ] || { printf "Update validation failed: required directory %s is missing.\n" "$f" >&2; return 2; }
  done
  for f in install.sh uninstall.sh config/config.example lib/update.sh lib/update-guard.php lib/config-options.php; do
    [ -s "$src/$f" ] && [ ! -L "$src/$f" ] || { printf "Update validation failed: required file %s is missing.\n" "$f" >&2; return 2; }
  done
  [ -s "$src/VERSION" ] || { printf 'Update validation failed: VERSION is missing.\n' >&2; return 2; }
  [ -s "$src/pressgarden" ] || { printf 'Update validation failed: pressgarden CLI is missing.\n' >&2; return 2; }
  [ -s "$src/lib/_lib.sh" ] || { printf 'Update validation failed: runtime library is missing.\n' >&2; return 2; }

  [ "$(cat "$src/PRODUCT" 2>/dev/null)" = "PressGarden" ] || { printf "Update identity mismatch.\n" >&2; return 2; }
  version=$(tr -d '[:space:]' < "$src/VERSION" 2>/dev/null || true)
  case "$version" in ''|*[!0-9A-Za-z._+-]*) printf 'Update validation failed: invalid VERSION value.\n' >&2; return 2 ;; esac

  list=$(_pg_update_tmpf) || return 2
  : > "$list"
  find "$src/checks" "$src/lib" "$src/tests" -type f \( -name '*.sh' -o -name 'pressgarden' \) -print 2>/dev/null >> "$list" || { rm -f "$list"; return 2; }
  printf '%s\n' "$src/pressgarden" "$src/install.sh" "$src/uninstall.sh" >> "$list"
  sort -u "$list" -o "$list" 2>/dev/null || { rm -f "$list"; return 2; }
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ! bash -n "$f" 2>/dev/null; then
      printf 'Update validation failed: Bash syntax error in %s.\n' "${f#"$src"/}" >&2
      rm -f "$list"
      return 2
    fi
  done < "$list"
  rm -f "$list"

  if command -v php >/dev/null 2>&1; then
    list=$(_pg_update_tmpf) || return 2
    find "$src/lib" -type f -name '*.php' -print 2>/dev/null > "$list"
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      if ! php -l "$f" >/dev/null 2>&1; then
        printf 'Update validation failed: PHP syntax error in %s.\n' "${f#"$src"/}" >&2
        rm -f "$list"
        return 2
      fi
    done < "$list"
    rm -f "$list"
  fi
  return 0
}

_pg_update_backup_managed() {
  local target="$1" backup="$2" item src dest
  mkdir -p "$backup" || return 2
  for item in "${_PRESSGARDEN_UPDATE_MANAGED[@]}"; do
    src="$target/$item"; dest="$backup/$item"
    if [ -e "$src" ] || [ -L "$src" ]; then
      mkdir -p "$(dirname "$dest")" || return 2
      cp -a "$src" "$dest" || return 2
    fi
  done
  if [ -e "$target/config/config.example" ] || [ -L "$target/config/config.example" ]; then
    mkdir -p "$backup/config" || return 2
    cp -a "$target/config/config.example" "$backup/config/config.example" || return 2
  fi
  : > "$backup/.complete" || return 2
}

_pg_update_replace_managed() {
  local src="$1" target="$2" item from to
  for item in "${_PRESSGARDEN_UPDATE_MANAGED[@]}"; do
    from="$src/$item"; to="$target/$item"
    rm -rf -- "$to" || return 2
    if [ -e "$from" ] || [ -L "$from" ]; then
      mkdir -p "$(dirname "$to")" || return 2
      cp -a "$from" "$to" || return 2
    fi
  done

  # Only the public example is distribution-managed. The user's real config is
  # intentionally neither removed, rewritten, merged, nor parsed here.
  mkdir -p "$target/config" || return 2
  rm -f -- "$target/config/config.example" || return 2
  cp -a "$src/config/config.example" "$target/config/config.example" || return 2

  chmod +x "$target/pressgarden" "$target/install.sh" "$target/uninstall.sh" 2>/dev/null || return 2
  chmod +x "$target"/checks/*.sh 2>/dev/null || return 2
  return 0
}

_pg_update_restore_managed() {
  local backup="$1" target="$2" item from to failed=0
  [ -f "$backup/.complete" ] || return 2
  for item in "${_PRESSGARDEN_UPDATE_MANAGED[@]}" config/config.example; do
    to="$target/$item"; from="$backup/$item"
    if ! rm -rf -- "$to"; then failed=1; continue; fi
    if [ -e "$from" ] || [ -L "$from" ]; then
      mkdir -p "$(dirname "$to")" && cp -a "$from" "$to" || failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

# Runs in the updater's subshell. Never discard the only recovery copy after a
# failed rollback, and never steal/remove another process's update lock.
_pg_update_exit() {
  local rc="$1"
  trap - EXIT
  trap '' HUP INT TERM
  if [ "${_pg_update_dirty:-0}" = 1 ]; then
    printf '\nUpdate did not complete; restoring previous program files...\n' >&2
    if ! _pg_update_restore_managed "$_pg_update_workspace/backup" "$PRESSGARDEN_DIR"; then
      printf 'ROLLBACK INCOMPLETE. Recovery files retained at: %s/backup\n' "$_pg_update_workspace" >&2
      printf 'Update lock retained. Do not delete the recovery directory; see docs/UPDATING.md.\n' >&2
      return 2
    fi
    printf 'Previous program restored. Private configuration and runtime data were not replaced.\n' >&2
  fi
  if [ -n "${_pg_update_workspace:-}" ]; then rm -rf -- "$_pg_update_workspace" || rc=2; fi
  if [ "${_pg_update_lock_owned:-0}" = 1 ]; then
    rm -f -- "$_pg_update_lock/pid" "$_pg_update_lock/workspace" || rc=2
    rmdir -- "$_pg_update_lock" || rc=2
  fi
  return "$rc"
}


pg_update() (
  # Subshell-local traps/umask leave callers unchanged. The workspace lives next
  # to the install, not in a system temp directory that may be cleared on reboot.
  set -uo pipefail
  umask 077
  local archive src backup old_version new_version item private_config
  _pg_update_workspace=''; _pg_update_dirty=0; _pg_update_lock_owned=0
  PRESSGARDEN_DIR=$(cd -P "$PRESSGARDEN_DIR" 2>/dev/null && pwd -P) || return 2
  _pg_update_lock="$PRESSGARDEN_DIR/.pressgarden-update.lock"
  trap '_pg_update_exit "$?"; exit $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ -e "$PRESSGARDEN_DIR/.git" ] && [ "${PRESSGARDEN_UPDATE_ALLOW_GIT:-0}" != "1" ]; then
    printf 'PressGarden update refused: this appears to be a Git checkout. Use git pull for a development checkout.\n' >&2
    return 2
  fi
  [ -s "$PRESSGARDEN_DIR/pressgarden" ] && [ -s "$PRESSGARDEN_DIR/VERSION" ] && [ -s "$PRESSGARDEN_DIR/lib/_lib.sh" ] || {
    printf 'Update refused: target is not a complete PressGarden installation.\n' >&2; return 2;
  }
  [ -w "$PRESSGARDEN_DIR" ] || { printf 'PressGarden program directory is not writable.\n' >&2; return 2; }
  command -v tar >/dev/null 2>&1 || { printf 'PressGarden update requires tar.\n' >&2; return 2; }
  command -v php >/dev/null 2>&1 && php -r 'exit(function_exists("gzopen") ? 0 : 2);' || {
    printf 'PressGarden update requires PHP CLI with zlib for safe archive validation.\n' >&2; return 2;
  }
  [[ "$PRESSGARDEN_UPDATE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] &&
    [[ "$PRESSGARDEN_UPDATE_REF" =~ ^[A-Za-z0-9_][A-Za-z0-9_./+-]*$ ]] || {
      printf 'Invalid update repository or ref.\n' >&2; return 2;
    }

  if ! mkdir -- "$_pg_update_lock" 2>/dev/null; then
    printf 'Update refused: another update is running or a recovery lock remains. See docs/UPDATING.md.\n' >&2
    return 2
  fi
  _pg_update_lock_owned=1
  printf '%s\n' "$BASHPID" > "$_pg_update_lock/pid" || return 2
  for item in "${_PRESSGARDEN_UPDATE_MANAGED[@]}" config; do
    [ ! -L "$PRESSGARDEN_DIR/$item" ] || { printf 'Update refused: managed path %s is a symbolic link.\n' "$item" >&2; return 2; }
  done
  private_config="${CONFIG_FILE:-${PRESSGARDEN_CONFIG_FILE:-$PRESSGARDEN_DIR/config/config}}"
  php "$PRESSGARDEN_DIR/lib/update-guard.php" layout "$PRESSGARDEN_DIR" \
    "${_PRESSGARDEN_UPDATE_MANAGED[@]}" config/config.example --private \
    "$private_config" "$PRESSGARDEN_DIR/config/config" "$PRESSGARDEN_DIR/var" \
    "${PRESSGARDEN_STATE_DIR:-}" "${PRESSGARDEN_CACHE_DIR:-}" "${PRESSGARDEN_BACKUPS_DIR:-}" \
    "${REPORTS:-}" "${PRESSGARDEN_BACKUPS_DIR:-}" || return 2

  _pg_update_workspace=$(mktemp -d "$PRESSGARDEN_DIR/.pressgarden-update.XXXXXX") || return 2
  printf '%s\n' "$_pg_update_workspace" > "$_pg_update_lock/workspace" || return 2
  archive="$_pg_update_workspace/pressgarden.tar.gz"; src="$_pg_update_workspace/src"; backup="$_pg_update_workspace/backup"
  mkdir -p "$src" || return 2
  old_version=$(tr -d '[:space:]' < "$PRESSGARDEN_DIR/VERSION")
  printf 'Checking PressGarden updates from %s @ %s...\n' "$PRESSGARDEN_UPDATE_REPO" "$PRESSGARDEN_UPDATE_REF"
  _pg_update_fetch_archive "$archive" || return 2
  # Use the installed validator, never code from the still-untrusted download.
  php "$PRESSGARDEN_DIR/lib/update-guard.php" archive "$archive" || return 2
  if ! (unset TAR_OPTIONS GZIP; tar -xzf "$archive" -C "$src" --strip-components=1 --no-same-owner --no-same-permissions); then
    printf 'Update validation failed: downloaded archive could not be extracted.\n' >&2; return 2
  fi
  _pg_update_validate_source "$src" || return 2
  new_version=$(tr -d '[:space:]' < "$src/VERSION")
  printf 'Validated PressGarden v%s. Preserving config and runtime data...\n' "$new_version"
  _pg_update_backup_managed "$PRESSGARDEN_DIR" "$backup" || { printf 'Update aborted: could not create a complete rollback copy.\n' >&2; return 2; }
  _pg_update_dirty=1
  _pg_update_replace_managed "$src" "$PRESSGARDEN_DIR" || return 2
  _pg_update_validate_source "$PRESSGARDEN_DIR" || return 2
  _pg_update_dirty=0

  if [ "$old_version" = "$new_version" ]; then
    printf '\n✓ PressGarden code refreshed: v%s (%s @ %s)\n' "$new_version" "$PRESSGARDEN_UPDATE_REPO" "$PRESSGARDEN_UPDATE_REF"
  else
    printf '\n✓ PressGarden updated: %s → %s\n' "$old_version" "$new_version"
  fi
  printf '✓ Preserved: config/config, reports, backups, and cache\n'
  printf '✓ Program:   %s\n' "$PRESSGARDEN_DIR"
  if [ -f "$PRESSGARDEN_DIR/lib/config-options.php" ]; then
    php "$PRESSGARDEN_DIR/lib/config-options.php" "$PRESSGARDEN_DIR/config/config.example" "$private_config" --brief ||
      printf 'Configuration comparison unavailable; your private config was not changed.\n' >&2
  fi
  # A transient feed failure must not roll back successfully installed code.
  : # no threat feeds in this product "$new_version" || return 1
  printf '\nRun ./pressgarden doctor to verify the environment after a major update.\n'
  return 0
)
