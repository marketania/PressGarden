#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

make_site() {
  local name="$1" p
  p="$T/sites/$name/public_html"
  mkdir -p "$p/wp-admin" "$p/wp-content" "$p/wp-includes"
  touch "$p/wp-load.php" "$p/wp-settings.php"
  printf '<?php $wp_version="7.1";\n' > "$p/wp-includes/version.php"
  printf '<?php\n' > "$p/wp-config.php"
}
make_site example.com
make_site other.com
make_site broken.com

touch "$T/sites/example.com/public_html/.litespeed-installed" "$T/sites/example.com/public_html/.litespeed-active"
touch "$T/sites/broken.com/public_html/.bootstrap-fail"

cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
set -eu
orig=("$@")
p=''; args=()
for a in "$@"; do
  case "$a" in
    --path=*) p=${a#--path=} ;;
    --skip-plugins|--skip-themes|--skip-packages|--no-color) ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"
[ -n "$p" ] || p="$PWD"

# Real LiteSpeed database commands must never receive ordinary WP-CLI globals.
if [ "${1:-}" = litespeed-database ]; then
  for a in "${orig[@]}"; do case "$a" in --*) echo 'unexpected WP-CLI global parameter' >&2; exit 96 ;; esac; done
fi

count_action() {
  local blog="$1" action="$2"
  [ -f "$p/.actions" ] || { echo 0; return; }
  grep -c "^$blog $action$" "$p/.actions" 2>/dev/null || true
}

emit_state() {
  [ -f "$p/.litespeed-active" ] || exit 98
  # The state probe must load LiteSpeed; --skip-plugins would make the real
  # DB_Optm class unavailable.
  for a in "${orig[@]}"; do [ "$a" != --skip-plugins ] || { echo 'state probe skipped plugins' >&2; exit 83; }; done
  blog=${PRESSGARDEN_LSDB_BLOG:-single}
  if [ -f "$p/.already" ]; then
    printf 'PWLSDB1\tOK\t%s\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t900000\n' "${blog/single/1}"
    return
  fi
  if [ -f "$p/.unverified" ]; then
    printf 'PWLSDB1\tOK\t%s\t4\t2\t1\t1\t3\t2\t1\t5\t10\t3\t1000000\n' "${blog/single/1}"
    return
  fi
  posts=$(count_action "$blog" clear_posts)
  comments=$(count_action "$blog" clear_comments)
  tracks=$(count_action "$blog" clear_trackbacks)
  trans=$(count_action "$blog" clear_transients)
  tables=$(count_action "$blog" optimize_tables)
  if [ "$posts" -eq 0 ]; then rev=4; orph=2; auto=1; trash=1
  elif [ "$posts" -eq 1 ]; then rev=0; orph=1; auto=0; trash=0
  else rev=0; orph=0; auto=0; trash=0; fi
  if [ "$comments" -eq 0 ]; then spam=3; trashc=2; else spam=0; trashc=0; fi
  if [ "$tracks" -eq 0 ]; then track=1; else track=0; fi
  if [ "$trans" -eq 0 ]; then exp=5; transient=10; else exp=0; transient=0; fi
  if [ "$tables" -eq 0 ]; then opt=3; else opt=0; fi
  if [ "$rev" -eq 0 ] && [ "$orph" -eq 0 ] && [ "$auto" -eq 0 ] && [ "$trash" -eq 0 ] && [ "$spam" -eq 0 ] && [ "$trashc" -eq 0 ] && [ "$track" -eq 0 ] && [ "$exp" -eq 0 ] && [ "$transient" -eq 0 ] && [ "$opt" -eq 0 ]; then size=900000; else size=1000000; fi
  printf 'PWLSDB1\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${blog/single/1}" "$rev" "$orph" "$auto" "$trash" "$spam" "$trashc" "$track" "$exp" "$transient" "$opt" "$size"
}

case "${1:-}" in
  db)
    [ "${2:-}" = export ] || exit 99
    [ ! -f "$p/.backup-fail" ] || exit 40
    printf '%s\n' '-- SQL dump fixture, not real credentials' > "$3"
    ;;
  core)
    [ "${2:-}" = is-installed ] || exit 90
    [ ! -f "$p/.bootstrap-fail" ] || exit 91
    if [ "${3:-}" = --network ]; then [ -f "$p/.multisite" ]; else exit 0; fi
    ;;
  plugin)
    [ ! -f "$p/.bootstrap-fail" ] || exit 91
    case "${2:-}" in
      is-installed) [ "${3:-}" = litespeed-cache ] && [ -f "$p/.litespeed-installed" ] ;;
      is-active) [ "${3:-}" = litespeed-cache ] && [ -f "$p/.litespeed-active" ] ;;
      *) exit 92 ;;
    esac
    ;;
  help)
    [ "${2:-}" = litespeed-database ] || exit 93
    printf '%s\n' "${3:-family}" >> "$p/.help-calls"
    case "${3:-}" in ''|clear_posts|clear_comments|clear_trackbacks|clear_transients|optimize_tables) : ;; *) exit 93 ;; esac
    [ -f "$p/.litespeed-active" ] || exit 94
    [ ! -f "$p/.no-litespeed-command" ] || exit 95
    ;;
  site)
    [ "${2:-}" = list ] || exit 88
    [ -f "$p/.multisite" ] || exit 89
    [ "${3:-}" = --field=blog_id ] || exit 87
    if [ -f "$p/.bad-blog-list" ]; then printf '1\nbad\n'; else printf '1\n2\n'; fi
    ;;
  eval-file)
    emit_state
    ;;
  litespeed-database)
    action=${2:-}
    case "$action" in clear_posts|clear_comments|clear_trackbacks|clear_transients|optimize_tables) : ;; *) exit 97 ;; esac
    [ -f "$p/.litespeed-active" ] || exit 98
    if [ -f "$p/.multisite" ]; then
      [ "${3:-}" = blog ] || exit 86
      case "${4:-}" in ''|*[!0-9]*) exit 85 ;; esac
      blog=$4
    else
      [ "$#" -eq 2 ] || exit 84
      blog=single
    fi
    if [ -f "$p/.fail-$action" ]; then echo "simulated $action failure" >&2; exit 41; fi
    printf '%s %s\n' "$blog" "$action" >> "$p/.actions"
    echo "Success: $action completed."
    ;;
  *) exit 99 ;;
esac
WP
chmod +x "$T/bin/wp"

export PATH="$T/bin:$PATH"
export PRESSGARDEN_SCAN_ROOT="$T/sites"
export PRESSGARDEN_CONFIG_FILE="$T/no-config"
export PRESSGARDEN_STATE_DIR="$T/state"
export PRESSGARDEN_CACHE_DIR="$T/cache"
export PRESSGARDEN_INTERACTIVE=0
export PRESSGARDEN_NOCOLOR=1
export PRESSGARDEN_PROGRESS=0
run(){ bash "$REPO/pressgarden" "$@"; }

# The probe implementation is intentionally bound to LiteSpeed's own UI counter
# implementation rather than PressGarden-maintained approximate SQL.
grep -q 'LiteSpeed\\DB_Optm::cls' "$REPO/lib/litespeed-db-state.php"
grep -q 'db_count($type, true)' "$REPO/lib/litespeed-db-state.php"

# Fleet status now shows the real current counters, while retaining honest skip
# and bootstrap-error classification.
set +e
run litespeed-db status all > "$T/status" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q 'example.com' "$T/status"
grep -q 'Post revisions:.*4' "$T/status"
grep -q 'CLEANUP AVAILABLE' "$T/status"
grep -q 'other.com' "$T/status"; grep -q 'UNAVAILABLE.*not installed' "$T/status"
grep -q 'broken.com' "$T/status"; grep -q 'ERROR.*bootstrap failed' "$T/status"

# Fleet optimization must begin maintaining eligible sites immediately instead
# of running a five-subcommand help preflight across the whole fleet first.
rm -f "$T/sites/example.com/public_html/.actions" "$T/sites/example.com/public_html/.help-calls"
set +e
run litespeed-db optimize all > "$T/fleet-optimize" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]  # broken.com remains an honest fleet error
[ -s "$T/sites/example.com/public_html/.actions" ]
grep -q 'Execution: streaming per installation' "$T/fleet-optimize"
grep -q 'example.com' "$T/fleet-optimize"
grep -q '✓ VERIFIED' "$T/fleet-optimize"
grep -q 'other.com' "$T/fleet-optimize"; grep -q 'UNAVAILABLE.*not installed' "$T/fleet-optimize"
grep -q 'broken.com' "$T/fleet-optimize"; grep -q 'ERROR.*bootstrap failed' "$T/fleet-optimize"
grep -q 'Optimized + verified:.*1' "$T/fleet-optimize"
grep -q 'LiteSpeed unavailable:.*1' "$T/fleet-optimize"
grep -q 'Failed:.*1' "$T/fleet-optimize"
help_calls=$(wc -l < "$T/sites/example.com/public_html/.help-calls" 2>/dev/null || printf '0')
[ "${help_calls:-0}" -le 1 ] || { echo "fleet preflight used too many LiteSpeed help probes: $help_calls" >&2; exit 1; }
! grep -q 'Preflight complete:' "$T/fleet-optimize"

# Dedicated command accepts --target, while a mistaken --hostname receives a
# PressGarden correction instead of falling through to site/WP-CLI errors.
run litespeed-db status --target example.com > "$T/status-target" 2>&1
grep -q 'example.com' "$T/status-target"
set +e
run litespeed-db optimize --example.com > "$T/bad-target" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q 'Invalid PressGarden target syntax: --example.com' "$T/bad-target"
grep -q './pressgarden litespeed-db optimize example.com' "$T/bad-target"
! grep -q 'Website not found' "$T/bad-target"

# One-site maintenance must show BEFORE/ACTION/AFTER, run documented command
# groups without globals, retry residual post cleanup, and verify all UI counters.
rm -f "$T/sites/example.com/public_html/.actions"
run litespeed-db optimize example.com > "$T/verified" 2>&1
[ "$(grep -c '^single clear_posts$' "$T/sites/example.com/public_html/.actions")" -eq 2 ]
[ "$(grep -c '^single clear_comments$' "$T/sites/example.com/public_html/.actions")" -eq 1 ]
[ "$(grep -c '^single clear_trackbacks$' "$T/sites/example.com/public_html/.actions")" -eq 1 ]
[ "$(grep -c '^single clear_transients$' "$T/sites/example.com/public_html/.actions")" -eq 1 ]
[ "$(grep -c '^single optimize_tables$' "$T/sites/example.com/public_html/.actions")" -eq 1 ]
! grep -q 'optimize_all' "$T/sites/example.com/public_html/.actions"
grep -q '^    BEFORE$' "$T/verified"
grep -q '^    OPTIMIZING$' "$T/verified"
grep -q '^    VERIFYING RESIDUALS$' "$T/verified"
grep -q '^    AFTER$' "$T/verified"
grep -q 'Post revisions:.*0' "$T/verified"
grep -q 'Orphaned post meta:.*0' "$T/verified"
grep -q '✓ VERIFIED.*all dashboard counters are zero' "$T/verified"
grep -q 'Database before:' "$T/verified"
grep -q 'Estimated reduction:' "$T/verified"
grep -q 'Post revisions net decrease:.*4' "$T/verified"
grep -q 'Overhead-table net decrease:.*3' "$T/verified"

# A site already clean must not be mutated merely to manufacture a success line.
rm -f "$T/sites/example.com/public_html/.actions"; touch "$T/sites/example.com/public_html/.already"
run litespeed-db optimize example.com > "$T/already" 2>&1
[ ! -s "$T/sites/example.com/public_html/.actions" ]
grep -q 'ALREADY OPTIMIZED' "$T/already"
rm -f "$T/sites/example.com/public_html/.already"

# Exit zero from every LiteSpeed command is insufficient: unchanged/nonzero
# counters must make the result UNVERIFIED and the command return incomplete.
rm -f "$T/sites/example.com/public_html/.actions"; touch "$T/sites/example.com/public_html/.unverified"
set +e
run litespeed-db optimize example.com > "$T/unverified" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q '⚠ UNVERIFIED' "$T/unverified"
grep -q 'dashboard counters remain non-zero' "$T/unverified"
grep -q 'Unverified:.*1' "$T/unverified"
rm -f "$T/sites/example.com/public_html/.unverified"

# A real action failure remains FAILED even when later state can still be read.
rm -f "$T/sites/example.com/public_html/.actions"; touch "$T/sites/example.com/public_html/.fail-clear_comments"
set +e
run litespeed-db optimize example.com > "$T/failure" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q 'spam + trashed comments failed (exit 41)' "$T/failure"
grep -q '✖ FAILED' "$T/failure"
rm -f "$T/sites/example.com/public_html/.fail-clear_comments"

# An active plugin missing one required documented command is a preflight error.
touch "$T/sites/other.com/public_html/.litespeed-installed" "$T/sites/other.com/public_html/.litespeed-active" "$T/sites/other.com/public_html/.no-litespeed-command"
set +e
run litespeed-db status other.com > "$T/unavailable" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q 'LiteSpeed database command family is unavailable' "$T/unavailable"
rm -f "$T/sites/other.com/public_html/.litespeed-installed" "$T/sites/other.com/public_html/.litespeed-active" "$T/sites/other.com/public_html/.no-litespeed-command"

# Multisite must verify every validated blog separately and still present one
# installation-level BEFORE/AFTER result.
rm -f "$T/sites/example.com/public_html/.actions"; touch "$T/sites/example.com/public_html/.multisite"
run litespeed-db optimize example.com > "$T/multisite" 2>&1
for blog in 1 2; do
  [ "$(grep -c "^$blog clear_posts$" "$T/sites/example.com/public_html/.actions")" -eq 2 ]
  grep -q "^$blog optimize_tables$" "$T/sites/example.com/public_html/.actions"
done
grep -q 'Multisite blogs:.*2' "$T/multisite"
grep -q '✓ VERIFIED' "$T/multisite"

# Malformed multisite inventory starts no database action.
rm -f "$T/sites/example.com/public_html/.actions"; touch "$T/sites/example.com/public_html/.bad-blog-list"
set +e
run litespeed-db optimize example.com > "$T/bad-blogs" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
[ ! -s "$T/sites/example.com/public_html/.actions" ]
grep -q 'blog-ID inventory failed' "$T/bad-blogs"
rm -f "$T/sites/example.com/public_html/.bad-blog-list" "$T/sites/example.com/public_html/.multisite"

# An obsolete internal suite flag cannot authorize mutation in the new product.
rm -f "$T/sites/example.com/public_html/.actions"
PRESSGARDEN_SCAN_ROOT="$T/sites/example.com/public_html" PG_LITESPEED_DB_SUITE=1 \
  bash "$REPO/checks/litespeed-db.sh" > "$T/no-auto"
[ ! -s "$T/sites/example.com/public_html/.actions" ]
printf 'LiteSpeed DB state, scoped arguments, residual pass, multisite, failures, summary and no implicit suite mutation PASS\n'
