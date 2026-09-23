# Report files only: never alter site files, historical reports or config.
# No global umask change: WordPress remediation keeps its existing semantics.
pg_report_init() {
  local name="$1" stamp reservation file suffix failed=0
  local -a created=()
  case "$name" in ''|*[!A-Za-z0-9_-]*) printf 'INCOMPLETE: invalid report name.\n' >&2; return 2 ;; esac
  (umask 077; mkdir -p -- "$REPORTS") 2>/dev/null || {
    printf 'INCOMPLETE: cannot create reports directory.\n' >&2; return 2;
  }
  stamp=$(date +%Y%m%d-%H%M%S) || return 2
  # Reserve an unpredictable identifier; never rely on second-resolution time.
  reservation=$(mktemp -d "$REPORTS/.$name-$stamp.XXXXXX" 2>/dev/null) || {
    printf 'INCOMPLETE: cannot reserve a unique report identifier.\n' >&2; return 2;
  }
  PG_REPORT_ID=${reservation##*/}; PG_REPORT_ID=${PG_REPORT_ID#.}
  PG_REPORT_PREFIX="$REPORTS/$PG_REPORT_ID"
  # Keep flat .log / *-findings.log / *-summary.json naming for existing users.
  for suffix in .log -findings.log -deletions.log; do
    file="$PG_REPORT_PREFIX$suffix"
    if [ -e "$file" ] || [ -L "$file" ] || ! (umask 077; set -C; : > "$file") 2>/dev/null; then
      failed=1; break
    fi
    created+=("$file")
  done
  rmdir -- "$reservation" 2>/dev/null || failed=1
  if [ "$failed" -ne 0 ]; then
    for file in "${created[@]}"; do rm -f -- "$file"; done
    printf 'INCOMPLETE: cannot initialize private report files; existing paths were not overwritten.\n' >&2
    return 2
  fi
  LOG="$PG_REPORT_PREFIX.log"
  DETAIL_LOG="$PG_REPORT_PREFIX-findings.log"
  DELETE_LOG="$PG_REPORT_PREFIX-deletions.log"
  PG_REPORT_FAILED=0
}

pg_report_failure() {
  PG_REPORT_FAILED=1
  printf 'INCOMPLETE: finding details could not be saved; generic file actions are disabled for this check.\n' >&2
}

pg_report_remove_empty() {
  local file
  for file in "${DETAIL_LOG:-}" "${DELETE_LOG:-}"; do
    [ -n "$file" ] || continue
    # These paths were exclusively created by this invocation. Never traverse
    # a subsequently replaced symlink/directory during best-effort cleanup.
    if [ -f "$file" ] && [ ! -L "$file" ] && [ ! -s "$file" ]; then rm -f -- "$file"; fi
  done
  return 0
}
