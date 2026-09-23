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
  touch "$p/.litespeed-installed" "$p/.litespeed-active"
}
make_site example.com
make_site other.com

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

case "${1:-}" in
  eval-file)
    case "${2:-}" in */litespeed-secret-command.php) :;; *) exit 97;; esac
    printf '%s\n' "$*" > "$p/.last-command"; echo Success
    ;;
  db)
    [ "${2:-}" = export ] || exit 99
    [ ! -f "$p/.backup-fail" ] || exit 40
    printf '%s\n' '-- SQL dump fixture, not real credentials' > "$3"
    ;;
  core)
    [ "${2:-}" = is-installed ] || exit 90
    if [ "${3:-}" = --network ]; then [ -f "$p/.multisite" ]; else exit 0; fi
    ;;
  plugin)
    case "${2:-}" in
      is-installed) [ "${3:-}" = litespeed-cache ] && [ -f "$p/.litespeed-installed" ] ;;
      is-active) [ "${3:-}" = litespeed-cache ] && [ -f "$p/.litespeed-active" ] ;;
      get) [ "${3:-}" = litespeed-cache ] || exit 91; echo '7.5.0' ;;
      *) exit 92 ;;
    esac
    ;;
  help)
    case "${2:-}" in
      litespeed-database)
        case "${3:-}" in
          ''|clear_posts|clear_comments|clear_trackbacks|clear_transients|optimize_tables|optimize_all) exit 0 ;;
          *) exit 93 ;;
        esac
        ;;
      litespeed-option|litespeed-purge|litespeed-presets|litespeed-image|litespeed-online|litespeed-debug|litespeed-crawler) exit 0 ;;
      *) exit 93 ;;
    esac
    ;;
  litespeed-option)
    sub=${2:-}; shift 2 || true
    case "$sub" in
      export)
        file=''; for a in "$@"; do case "$a" in --filename=*) file=${a#--filename=} ;; esac; done
        [ -n "$file" ] || exit 94; mkdir -p "$(dirname "$file")"; printf 'cache=true\napi_key=backup-secret\n' > "$file"; echo "Exported $file"
        ;;
      get) if [ "${1:-}" = api_key ]; then echo 'super-secret-api-value'; elif [ -f "$p/.option-value" ]; then cat "$p/.option-value"; else echo true; fi ;;
      all) printf 'cache=true\napi_key=super-secret-api-value\ntoken=very-secret-token\n' ;;
      set) printf '%s\n' "$2" > "$p/.option-value"; printf '%s\n' "$sub $*" > "$p/.last-command"; echo 'Success' ;;
      import|import_remote|reset) printf '%s\n' "$sub $*" > "$p/.last-command"; echo 'Success' ;;
      *) exit 95 ;;
    esac
    ;;
  litespeed-purge|litespeed-presets|litespeed-image|litespeed-online|litespeed-debug|litespeed-crawler)
    printf '%s\n' "$*" > "$p/.last-command"
    if [ "$1" = litespeed-online ] && [ "${2:-}" = link ]; then printf 'api_key=should-not-print\n'; else echo 'Success'; fi
    ;;
  litespeed-database)
    for a in "${orig[@]}"; do case "$a" in --*) echo 'database received forbidden global arg' >&2; exit 96 ;; esac; done
    printf '%s\n' "$*" > "$p/.last-command"; echo 'Database success'
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
run_check(){ ROOT="$T/sites" PRESSGARDEN_DIR="$REPO" bash "$REPO/checks/litespeed.sh" "$@"; }
run_cli(){ bash "$REPO/pressgarden" "$@"; }

# Fleet status inventories all eight documented LiteSpeed WP-CLI families.
run_check status > "$T/status"
grep -q 'example.com.*8/8 command families' "$T/status"
grep -q 'other.com.*8/8 command families' "$T/status"

# Options: read, redact, set with a private pre-change backup, import variants, reset.
run_check option all --format=json > "$T/options"
grep -q 'cache=true' "$T/options"
! grep -q 'super-secret-api-value' "$T/options"
! grep -q 'very-secret-token' "$T/options"
run_check option get api_key > "$T/get-secret"
grep -q 'REDACTED sensitive option value' "$T/get-secret"
run_check option set cache false > "$T/set"
find "$T/state/backups/litespeed-options" -type f | grep -q .
grep -q 'set cache false' "$T/sites/example.com/public_html/.last-command"
printf 'cache=true\n' > "$T/import.txt"
run_check option import "$T/import.txt" > /dev/null
run_check option import-remote https://example.test/options.txt > /dev/null
run_check option reset > /dev/null

# Private fleet exports must produce one file per site; one shared explicit path is refused.
run_check option export > "$T/export"
[ "$(find "$T/state/backups/litespeed-exports" -type f | wc -l)" -ge 2 ]
if run_check option export --filename="$T/one.txt" >/dev/null 2>&1; then echo 'fleet export overwrite protection failed' >&2; exit 1; fi

# Purge family: all documented variants.
run_check purge network-list > /dev/null
run_check purge all > /dev/null
run_check purge url https://example.com/path > /dev/null
run_check purge blog 2 > /dev/null
run_check purge category 1 3 5 > /dev/null
run_check purge tag 2 4 > /dev/null
run_check purge post-id 7 8 > /dev/null

# Presets family.
run_check presets backups > /dev/null
run_check presets apply basic > /dev/null
run_check presets restore 1667485245 > /dev/null

# Image optimization family, including irreversible backup removal guard.
run_check image status > /dev/null
run_check image push > /dev/null
run_check image pull > /dev/null
run_check image clean > /dev/null
run_check image switch optm > /dev/null
if run_check image remove-backups >/dev/null 2>&1; then echo 'destructive image backup removal guard failed' >&2; exit 1; fi
PRESSGARDEN_LITESPEED_DESTRUCTIVE=1 run_check image remove-backups > /dev/null

# QUIC.cloud online family. Secrets are sourced from env and redacted from output.
run_check online sync --format=json > /dev/null
run_check online services --format=csv > /dev/null
run_check online nodes --format=table > /dev/null
run_check online ping img_optm --force > /dev/null
run_check online cdn-status > /dev/null
run_check online init > /dev/null
export TEST_QC_KEY='qc-super-secret' TEST_CF_TOKEN='cf-super-secret'
run_check online link --email=test@example.com --api-key-env=TEST_QC_KEY > "$T/link"
! grep -q 'qc-super-secret\|should-not-print' "$T/link"
! grep -q 'qc-super-secret' "$T/sites/example.com/public_html/.last-command"
run_check online cdn-init --method=cfi --cf-token-env=TEST_CF_TOKEN > /dev/null

# Debug report is the one external-upload action that requires an additional
# non-interactive privacy opt-in.
if run_check debug send >/dev/null 2>&1; then echo 'debug external upload guard failed' >&2; exit 1; fi
PRESSGARDEN_LITESPEED_EXTERNAL=1 run_check debug send > /dev/null

# Crawler family.
run_check crawler list > /dev/null
run_check crawler enable 2 > /dev/null
run_check crawler disable 2 > /dev/null
run_check crawler run > /dev/null
run_check crawler reset > /dev/null

# Database family: every documented cleanup mode and optional multisite blog ID.
run_check database status > "$T/database-status"
grep -q 'example.com.*READY' "$T/database-status"
! grep -q 'litespeed-database status' "$T/database-status"
for action in clear-posts clear-comments clear-trackbacks clear-transients optimize-tables optimize-all; do
  run_check database "$action" --blog=2 > /dev/null
done
grep -q 'litespeed-database optimize_all blog 2' "$T/sites/example.com/public_html/.last-command"

# Top-level PressGarden accepts a positional target for LiteSpeed database
# actions, preserves explicit --target, and gives concise corrections for the
# common mistaken `--hostname` and top-level `database` forms.
rm -f "$T/sites/example.com/public_html/.last-command" "$T/sites/other.com/public_html/.last-command"
run_cli litespeed database optimize-all example.com > "$T/cli-positional" 2>&1
grep -q 'litespeed-database optimize_all' "$T/sites/example.com/public_html/.last-command"
[ ! -f "$T/sites/other.com/public_html/.last-command" ]
rm -f "$T/sites/example.com/public_html/.last-command"
run_cli litespeed database optimize-all --target example.com > "$T/cli-target" 2>&1
grep -q 'litespeed-database optimize_all' "$T/sites/example.com/public_html/.last-command"

set +e
run_cli litespeed database optimize-all --example.com > "$T/cli-bad-target" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q 'Invalid PressGarden target syntax: --example.com' "$T/cli-bad-target"
grep -q 'litespeed database optimize-all --target example.com' "$T/cli-bad-target"
! grep -q 'Areas and actions:' "$T/cli-bad-target"

set +e
run_cli database optimize-all --example.com > "$T/cli-top-database" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -q 'PressGarden has no top-level "database" command' "$T/cli-top-database"
grep -q 'litespeed-db optimize example.com' "$T/cli-top-database"
! grep -q 'PressGarden v' "$T/cli-top-database"

printf 'Full LiteSpeed CLI management: all documented families/subcommands, PressGarden targeting/corrections, redaction, backups, guards and DB invocation PASS\n'
