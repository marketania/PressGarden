#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ "$(cat "$DIR/PRODUCT" 2>/dev/null)" = PressGarden ] || { echo 'Product identity mismatch; refused.' >&2; exit 2; }
[ ! -d "$DIR/.git" ] || { echo 'Refusing to uninstall a Git working tree.' >&2; exit 2; }
[ "$#" -le 1 ] && { [ "$#" -eq 0 ] || [ "$1" = --yes ]; } || { echo 'Usage: uninstall.sh [--yes]' >&2; exit 2; }
if [ "${1:-}" != --yes ]; then
  answer=''; { exec 9<>/dev/tty; } 2>/dev/null || { echo 'Confirmation terminal required; or pass --yes.' >&2; exit 2; }
  printf 'Remove PressGarden program files from %s, keeping configuration and state? [y/N]: ' "$DIR" >&9
  IFS= read -r answer <&9 || true
  case "$answer" in y|Y|yes|YES) :;; *) echo 'Cancelled.'; exit 1;; esac
fi
# Never remove the installation directory, var/, saved config, or external state.
owned=(.github .gitignore CHANGELOG.md CONTRIBUTING.md LICENSE README.md SECURITY.md VERSION PRODUCT PROVENANCE.md checks docs lib tests config/config.example install.sh uninstall.sh pressgarden)
for item in "${owned[@]}"; do [ ! -L "$DIR/$item" ] || { echo 'Symlinked managed path refused.' >&2; exit 2; }; done
# Source trusted local config exactly as the CLI does, then reject private data
# under a program-owned directory. Preserve explicit caller overrides.
if [ -f "$DIR/.pressgarden-portable" ]; then default_config="$DIR/config/config"; default_state="$DIR/var"; default_cache="$DIR/var/cache"
else default_config="${XDG_CONFIG_HOME:-$HOME/.config}/pressgarden/config"; default_state="${XDG_STATE_HOME:-$HOME/.local/state}/pressgarden"; default_cache="${XDG_CACHE_HOME:-$HOME/.cache}/pressgarden"; fi
saved_config="${PRESSGARDEN_CONFIG_FILE:-$default_config}"
original_state="${PRESSGARDEN_STATE_DIR:-}"; original_cache="${PRESSGARDEN_CACHE_DIR:-}"; original_reports="${PRESSGARDEN_REPORTS_DIR:-}"
[ ! -r "$saved_config" ] || . "$saved_config"
private_state="${original_state:-${PRESSGARDEN_STATE_DIR:-$default_state}}"
private_cache="${original_cache:-${PRESSGARDEN_CACHE_DIR:-$default_cache}}"
private_reports="${original_reports:-${PRESSGARDEN_REPORTS_DIR:-$private_state/reports}}"
php "$DIR/lib/update-guard.php" layout "$DIR" "${owned[@]}" --private "$saved_config" "$private_state" "$private_cache" "$private_reports" "${PRESSGARDEN_BACKUPS_DIR:-$private_state/backups}" || exit 2
BIN="${PRESSGARDEN_BIN_DIR:-$HOME/.local/bin}"
if [ -L "$BIN/pressgarden" ] && [ "$(readlink "$BIN/pressgarden")" = "$DIR/pressgarden" ]; then rm -- "$BIN/pressgarden"; fi
for item in "${owned[@]}"; do rm -rf -- "$DIR/$item"; done
printf 'PressGarden program removed. Configuration, portable marker, and runtime state remain at %s and any configured external paths.\n' "$DIR"
