# Independent operations runtime; no threat scanner, quarantine or sibling calls.
pg_confirm() {
  local message="$1" answer=''
  [ "${PRESSGARDEN_INTERACTIVE:-1}" = 0 ] && return 0
  if { exec 9<>/dev/tty; } 2>/dev/null; then
    printf '\n%s [y/N]: ' "$message" >&9
    IFS= read -r answer <&9 || answer=''
    exec 9>&- 9<&-
    case "$answer" in y|Y|yes|YES) return 0 ;; esac
    printf 'Cancelled; no action authorized.\n' >&2
    return 1
  fi
  printf 'Refusing mutation without a terminal. Set PRESSGARDEN_INTERACTIVE=0 only for intentional automation.\n' >&2
  return 1
}

pg_safe_backup_dir() {
  php "$PRESSGARDEN_DIR/lib/ops-safety.php" backup-dir "$PRESSGARDEN_STATE_DIR" "$1" "$2"
}

pg_mutation_preflight() {
  # All discovered sites are checked before the first mutation. This also
  # prevents an explicitly configured backup path inside any website.
  require_wp; discover_sites
  php "$PRESSGARDEN_DIR/lib/ops-safety.php" scope "$PRESSGARDEN_STATE_DIR" "${WP_SITES[@]}"
}

finish() {
  printf '\nSummary: review items %s • non-compliant/failed items %s • elapsed %s\n' "$REVIEWS" "$ALERTS" "$(human_time "$(($(date +%s)-T0))")"
  [ "${PG_REPORT_FAILED:-0}" -eq 0 ] && [ "${PG_DISCOVERY_FAILED:-0}" -eq 0 ] && [ "${PG_CHECK_INCOMPLETE:-0}" -eq 0 ] || return 2
  [ "$TOTAL" -eq 0 ] || return 1
}

run_logged() {
  pg_report_init "$1" || return 2
  local -a result
  main 2>&1 | tee "$LOG"
  result=("${PIPESTATUS[@]}")
  local rc=${result[0]}
  if [ "${result[1]}" -ne 0 ] || [ "${PG_DISCOVERY_FAILED:-0}" -ne 0 ]; then
    printf 'INCOMPLETE: report or discovery failure.\n' >&2; rc=2
  fi
  pg_report_remove_empty
  return "$rc"
}

# Per-tool/per-installation writer lock. A second invocation must not overlap a
# backup/modify/verify cycle. FD 8 is reserved; commands release before next site.
pg_unlock_site() { exec 8>&- 8<&-; }
pg_lock_site() {
  local file expected opened
  command -v flock >/dev/null 2>&1 || { printf 'flock is required for mutation.\n' >&2; return 2; }
  file=$(php "$PRESSGARDEN_DIR/lib/ops-safety.php" lock-file "$PRESSGARDEN_STATE_DIR" "$1") || return 2
  expected=$(stat -c '%d:%i' "$file") || return 2
  exec 8<>"$file" || return 2
  opened=$(stat -Lc '%d:%i' "/proc/$$/fd/8" 2>/dev/null) || { pg_unlock_site; return 2; }
  [ "$expected" = "$opened" ] && [ ! -L "$file" ] && flock -n 8 || { printf 'Writer lock busy or unsafe; mutation refused.\n' >&2; pg_unlock_site; return 2; }
}
