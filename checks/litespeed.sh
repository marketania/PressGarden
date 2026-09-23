#!/usr/bin/env bash
set -uo pipefail
NAME=litespeed
DESC="LiteSpeed Cache full WP-CLI management"
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
. "$PRESSGARDEN_DIR/lib/database-backup.sh"

AREA="${1:-help}"; [ "$#" -gt 0 ] && shift || true
LS_MUTATES=0
LS_BACKUP=0
LS_EXTERNAL=0
LS_DESTRUCTIVE=0
LS_OUTPUT=1
LS_FAMILY=''
LS_SUB=''
LS_LABEL=''
LS_SENSITIVE_KEY=''
LS_USER_EXPORT=''
LS_DB_BLOG=''
LS_SECRET_ENV=''; LS_SECRET_FIELD=''
LS_ARGS=()

usage() {
  cat <<'EOF'
Usage: pressgarden litespeed AREA ACTION [arguments] [--target SITE]

Areas and actions:
  status
  option    get KEY | all [--format=FMT] | set KEY VALUE | export [--filename=PATH]
            import FILE | import-remote URL | reset
  purge     network-list | all | url URL | blog ID | category ID... | tag ID... | post-id ID...
  presets   apply PRESET | backups | restore BACKUP_NUMBER
  image     push | pull | status | clean | remove-backups | switch optm|orig
  online    init | sync [--format=FMT] | services [--format=FMT] | nodes [--format=FMT]
            ping SERVICE [--force] | cdn-status
            cdn-init --method=cname|ns|cfi [--cf-token-env=NAME] [--ssl-cert=PATH] [--ssl-key=PATH]
            link --email=EMAIL --api-key-env=NAME
  debug     send
  crawler   list | enable ID | disable ID | run | reset
  database  status | clear-posts | clear-comments | clear-trackbacks | clear-transients
            optimize-tables | optimize-all [--blog=ID]

Notes:
  --target / --site is parsed by the PressGarden CLI before this script runs.
  LiteSpeed database commands are executed from the WordPress directory without WP-CLI global flags.
  Other LiteSpeed command families use --path plus safe WP-CLI globals.
  Sensitive QUIC.cloud credentials should be supplied through environment variables, not shell-history arguments.
EOF
}

fail_usage() { printf 'PressGarden LiteSpeed input error: %s\n' "$1" >&2; printf 'Run ./pressgarden litespeed help for the full command list.\n' >&2; exit 2; }
_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_is_format() { case "${1:-}" in table|json|csv|yaml|ids|count) return 0 ;; *) return 1 ;; esac; }
_is_sensitive_name() { printf '%s' "${1:-}" | grep -Eiq '(api.?key|domain.?key|token|secret|password|passwd|private.?key|ssl.?key|auth|cookie|credential)'; }
_safe_label() { printf '%s' "$1" | tr '/[:space:]' '__' | tr -cd 'A-Za-z0-9._-'; }

_wp_builtin() {
  local site="$1"; shift
  wp "$@" --path="$site" --skip-plugins --skip-themes --skip-packages --no-color
}
_ls_standard() {
  local site="$1"; shift
  wp "$@" --path="$site" --skip-themes --skip-packages --no-color
}
_ls_database() {
  local site="$1"; shift
  (cd "$site" && wp litespeed-database "$@")
}
_wp_bootstrap_ok() { _wp_builtin "$1" core is-installed >/dev/null 2>&1; }
_lscwp_installed() { _wp_builtin "$1" plugin is-installed litespeed-cache >/dev/null 2>&1; }
_lscwp_active() { _wp_builtin "$1" plugin is-active litespeed-cache >/dev/null 2>&1; }
_lscwp_version() { _wp_builtin "$1" plugin get litespeed-cache --field=version 2>/dev/null | head -n1; }
_is_multisite() { _wp_builtin "$1" core is-installed --network >/dev/null 2>&1; }

_family_available() {
  local site="$1" family="$2" sub="${3:-}"
  if [ "$family" = database ]; then
    if [ -n "$sub" ]; then (cd "$site" && PAGER=cat WP_CLI_PAGER=cat wp help litespeed-database "$sub" >/dev/null 2>&1)
    else (cd "$site" && PAGER=cat WP_CLI_PAGER=cat wp help litespeed-database >/dev/null 2>&1); fi
  else
    if [ -n "$sub" ]; then _ls_standard "$site" help "litespeed-$family" "$sub" >/dev/null 2>&1
    else _ls_standard "$site" help "litespeed-$family" >/dev/null 2>&1; fi
  fi
}

_preflight() {
  local site="$1" probe_sub="$LS_SUB"
  # `database status` is a PressGarden inventory action, not a LiteSpeed
  # subcommand. Probe a real, representative command so status never calls
  # the nonexistent `wp help litespeed-database status`.
  if [ "$LS_FAMILY" = database ] && [ "$probe_sub" = status ]; then
    probe_sub=optimize_all
  fi
  if ! _wp_bootstrap_ok "$site"; then printf 'ERROR\tWordPress/WP-CLI bootstrap failed\n'; return; fi
  if ! _lscwp_installed "$site"; then printf 'SKIP\tLiteSpeed Cache is not installed\n'; return; fi
  if ! _lscwp_active "$site"; then printf 'SKIP\tLiteSpeed Cache is installed but inactive\n'; return; fi
  if [ -n "$LS_FAMILY" ] && ! _family_available "$site" "$LS_FAMILY" "$probe_sub"; then
    printf 'ERROR\tLiteSpeed command unavailable: litespeed-%s %s\n' "$LS_FAMILY" "$probe_sub"; return
  fi
  printf 'READY\tLiteSpeed Cache %s\n' "$(_lscwp_version "$site" || printf unknown)"
}

_redact_stream() {
  php "$PRESSGARDEN_DIR/lib/litespeed-output.php" redact
}
_show_output() {
  local file="$1" mode="${2:-full}"
  [ -s "$file" ] || return 0
  if { [ "$AREA" = online ] && [ "$LS_MUTATES" = 1 ]; } || [ "$AREA" = debug ]; then
    printf '        Provider response withheld to avoid disclosing credentials/support data.\n'; return 0
  fi
  if [ -n "$LS_SENSITIVE_KEY" ] && _is_sensitive_name "$LS_SENSITIVE_KEY" && [ "${PRESSGARDEN_LITESPEED_SHOW_SENSITIVE:-0}" != 1 ]; then
    printf '        [REDACTED sensitive option value]\n'
    return 0
  fi
  if [ "$mode" = bounded ]; then tr -d '\r' < "$file" | _redact_stream | head -20 | sed 's/^/        /'
  else tr -d '\r' < "$file" | _redact_stream | sed 's/^/        /'; fi
}

_backup_options() {
  local site="$1" label="$2" root file stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  root=$(pg_safe_backup_dir "$site" litespeed-options) || return 1
  file="$root/$(_safe_label "$label").txt"
  (umask 077; _ls_standard "$site" litespeed-option export "--filename=$file" >/dev/null 2>&1) || return 1
  php -r 'require $argv[1];$s=pg_ops_regular($argv[2]);if($s["size"]<1)exit(2);' "$PRESSGARDEN_DIR/lib/ops-safety.php" "$file" || return 1
  chmod 600 "$file" 2>/dev/null || true
  printf '%s' "$file"
}

_confirm() {
  local count="$1" text="$2" ans=''
  if [ "${PRESSGARDEN_INTERACTIVE:-1}" = 0 ]; then
    if [ "$LS_DESTRUCTIVE" = 1 ] && [ "${PRESSGARDEN_LITESPEED_DESTRUCTIVE:-0}" != 1 ]; then
      printf 'Refusing irreversible LiteSpeed action in non-interactive mode. Set PRESSGARDEN_LITESPEED_DESTRUCTIVE=1 intentionally.\n' >&2
      return 1
    fi
    if [ "$AREA" = debug ] && [ "${PRESSGARDEN_LITESPEED_EXTERNAL:-0}" != 1 ]; then
      printf 'Refusing non-interactive LiteSpeed support-report upload. Set PRESSGARDEN_LITESPEED_EXTERNAL=1 intentionally.\n' >&2
      return 1
    fi
    return 0
  fi
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '\n  %s for %s eligible site(s)? [y/N]: ' "$text" "$count" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=''
    case "$ans" in y|Y|yes|YES) return 0 ;; *) printf 'Cancelled.\n'; return 1 ;; esac
  fi
  printf 'Refusing LiteSpeed mutation without an interactive terminal. Set PRESSGARDEN_INTERACTIVE=0 only for intentional automation.\n' >&2
  return 1
}

_abs_file() {
  local p="$1" d b
  [ -e "$p" ] || return 1
  d=$(dirname "$p"); b=$(basename "$p")
  d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$d" "$b"
}

_parse_format_only() {
  local a="${1:-}"
  LS_ARGS=()
  [ "$#" -le 1 ] || fail_usage 'Too many format arguments.'
  if [ -n "$a" ]; then
    case "$a" in --format=*) a=${a#--format=} ;; *) fail_usage 'Use --format=table|json|csv|yaml|ids|count.' ;; esac
    _is_format "$a" || fail_usage 'Invalid output format.'
    LS_ARGS=("--format=$a")
  fi
}

_valid_option_key() {
  local pattern='^[[:alnum:]_][-[:alnum:]_]*(\[[[:alnum:]_-]+\])*$'
  [[ "$1" =~ $pattern ]]
}
_parse_option() {
  LS_FAMILY=option
  LS_SUB="${1:-all}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    get) [ "$#" -eq 1 ] || fail_usage 'option get requires KEY.'; _valid_option_key "$1" || fail_usage 'Invalid option key.'; LS_ARGS=("$1"); LS_SENSITIVE_KEY="$1"; LS_LABEL="get option $1" ;;
    all) _parse_format_only "$@"; LS_LABEL='list all options' ;;
    set) [ "$#" -eq 2 ] || fail_usage 'option set requires KEY VALUE.'; _valid_option_key "$1" || fail_usage 'Invalid option key.'; [[ "$2" != --* ]] || fail_usage 'Option value cannot begin with a CLI flag.'; LS_ARGS=("$1" "$2"); LS_SENSITIVE_KEY="$1"; LS_MUTATES=1; LS_BACKUP=1; LS_OUTPUT=0; LS_LABEL="set option $1" ;;
    export)
      [ "$#" -le 1 ] || fail_usage 'option export accepts only --filename=PATH.'
      if [ "$#" -eq 1 ]; then case "$1" in --filename=*) LS_USER_EXPORT=${1#--filename=} ;; *) fail_usage 'Use --filename=PATH.' ;; esac; fi
      LS_LABEL='export options'
      ;;
    import)
      [ "$#" -eq 1 ] || fail_usage 'option import requires FILE.'
      f=$(_abs_file "$1") || fail_usage 'Import file does not exist or cannot be resolved.'
      LS_ARGS=("$f"); LS_MUTATES=1; LS_BACKUP=1; LS_LABEL='import options'
      ;;
    import_remote|import-remote)
      LS_SUB=import_remote; [ "$#" -eq 1 ] || fail_usage 'option import-remote requires URL.'
      case "$1" in http://*|https://*) : ;; *) fail_usage 'Remote options URL must use http:// or https://.' ;; esac
      LS_ARGS=("$1"); LS_MUTATES=1; LS_BACKUP=1; LS_EXTERNAL=1; LS_LABEL='import remote options'
      ;;
    reset)
      [ "$#" -eq 0 ] || fail_usage 'option reset takes no arguments.'
      LS_MUTATES=1; LS_BACKUP=1; LS_LABEL='reset all LiteSpeed options to factory defaults'
      ;;
    *) fail_usage 'Unknown option action.' ;;
  esac
}

_parse_purge() {
  LS_FAMILY=purge; LS_SUB="${1:-}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    network_list|network-list) LS_SUB=network_list; [ "$#" -eq 0 ] || fail_usage 'purge network-list takes no arguments.'; LS_LABEL='list multisite network IDs' ;;
    all) [ "$#" -eq 0 ] || fail_usage 'purge all takes no arguments.'; LS_MUTATES=1; LS_LABEL='purge all LiteSpeed cache' ;;
    url) [ "$#" -eq 1 ] || fail_usage 'purge url requires URL.'; case "$1" in http://*|https://*) : ;; *) fail_usage 'Purge URL must be absolute http(s).' ;; esac; LS_ARGS=("$1"); LS_MUTATES=1; LS_LABEL='purge URL cache' ;;
    blog) [ "$#" -eq 1 ] && _is_uint "$1" || fail_usage 'purge blog requires numeric ID.'; LS_ARGS=("$1"); LS_MUTATES=1; LS_LABEL="purge blog $1" ;;
    category|tag)
      [ "$#" -ge 1 ] || fail_usage "purge $LS_SUB requires one or more numeric IDs."
      for x in "$@"; do _is_uint "$x" || fail_usage "purge $LS_SUB IDs must be numeric."; done
      LS_ARGS=("$@"); LS_MUTATES=1; LS_LABEL="purge $LS_SUB cache"
      ;;
    post_id|post-id)
      LS_SUB=post_id; [ "$#" -ge 1 ] || fail_usage 'purge post-id requires one or more numeric IDs.'
      for x in "$@"; do _is_uint "$x" || fail_usage 'purge post-id IDs must be numeric.'; done
      LS_ARGS=("$@"); LS_MUTATES=1; LS_LABEL='purge post cache'
      ;;
    *) fail_usage 'Unknown purge action.' ;;
  esac
}

_parse_presets() {
  LS_FAMILY=presets; LS_SUB="${1:-}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    apply) [ "$#" -eq 1 ] || fail_usage 'presets apply requires PRESET.'; case "$1" in *[!A-Za-z0-9_-]*|'') fail_usage 'Preset must be a simple name.' ;; esac; LS_ARGS=("$1"); LS_MUTATES=1; LS_BACKUP=1; LS_LABEL="apply preset $1" ;;
    get_backups|backups) LS_SUB=get_backups; [ "$#" -eq 0 ] || fail_usage 'presets backups takes no arguments.'; LS_LABEL='list preset backups' ;;
    restore) [ "$#" -eq 1 ] && _is_uint "$1" || fail_usage 'presets restore requires numeric backup number.'; LS_ARGS=("$1"); LS_MUTATES=1; LS_BACKUP=1; LS_LABEL="restore preset backup $1" ;;
    *) fail_usage 'Unknown presets action.' ;;
  esac
}

_parse_image() {
  LS_FAMILY=image; LS_SUB="${1:-}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    push|pull|clean) [ "$#" -eq 0 ] || fail_usage "image $LS_SUB takes no arguments."; LS_MUTATES=1; LS_EXTERNAL=1; LS_LABEL="image $LS_SUB" ;;
    status|s) LS_SUB=status; [ "$#" -eq 0 ] || fail_usage 'image status takes no arguments.'; LS_LABEL='image optimization status' ;;
    rm_bkup|remove-backups) LS_SUB=rm_bkup; [ "$#" -eq 0 ] || fail_usage 'image remove-backups takes no arguments.'; LS_MUTATES=1; LS_DESTRUCTIVE=1; LS_LABEL='permanently remove original image backups' ;;
    batch_switch|switch) LS_SUB=batch_switch; [ "$#" -eq 1 ] || fail_usage 'image switch requires optm or orig.'; case "$1" in optm|orig) : ;; *) fail_usage 'image switch must be optm or orig.' ;; esac; LS_ARGS=("$1"); LS_MUTATES=1; LS_LABEL="switch served images to $1" ;;
    *) fail_usage 'Unknown image action.' ;;
  esac
}

_parse_online() {
  LS_FAMILY=online; LS_SUB="${1:-}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    init) [ "$#" -eq 0 ] || fail_usage 'online init takes no arguments.'; LS_MUTATES=1; LS_EXTERNAL=1; LS_LABEL='initialize QUIC.cloud domain API key' ;;
    sync|services|nodes) _parse_format_only "$@"; LS_EXTERNAL=1; LS_LABEL="QUIC.cloud $LS_SUB" ;;
    ping)
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail_usage 'online ping requires SERVICE and optional --force.'
      case "$1" in img_optm|ccss|ucss|lqip|vpi) : ;; *) fail_usage 'Service must be img_optm, ccss, ucss, lqip, or vpi.' ;; esac
      LS_ARGS=("$1"); if [ "$#" -eq 2 ]; then [ "$2" = --force ] || fail_usage 'Only --force is supported after ping service.'; LS_ARGS+=(--force); fi
      LS_EXTERNAL=1; LS_LABEL="find QUIC.cloud node for $1"
      ;;
    cdn_status|cdn-status) LS_SUB=cdn_status; [ "$#" -eq 0 ] || fail_usage 'online cdn-status takes no arguments.'; LS_EXTERNAL=1; LS_LABEL='QUIC.cloud CDN status' ;;
    cdn_init|cdn-init)
      LS_SUB=cdn_init; LS_MUTATES=1; LS_EXTERNAL=1; LS_BACKUP=1; LS_LABEL='activate/configure QUIC.cloud CDN'
      local_method=''; cf_env=''; ssl_cert=''; ssl_key=''
      for x in "$@"; do
        case "$x" in
          --method=*) local_method=${x#--method=} ;;
          --cf-token-env=*) cf_env=${x#--cf-token-env=} ;;
          --ssl-cert=*) ssl_cert=${x#--ssl-cert=} ;;
          --ssl-key=*) ssl_key=${x#--ssl-key=} ;;
          --cf-token=*) fail_usage 'Do not place Cloudflare tokens in shell history. Use --cf-token-env=ENV_NAME.' ;;
          *) fail_usage "Unsupported cdn-init argument: $x" ;;
        esac
      done
      case "$local_method" in cname|ns|cfi) : ;; *) fail_usage 'cdn-init requires --method=cname|ns|cfi.' ;; esac
      LS_ARGS=("--method=$local_method")
      if [ -n "$cf_env" ]; then case "$cf_env" in *[!A-Za-z0-9_]*|'') fail_usage 'Invalid environment variable name.' ;; esac; [[ "$cf_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail_usage "Invalid environment reference."; [ -n "${!cf_env:-}" ] || fail_usage "Environment variable $cf_env is empty."; LS_SECRET_ENV="$cf_env"; LS_SECRET_FIELD=cf-token; fi
      [ -z "$ssl_cert" ] || LS_ARGS+=("--ssl-cert=$ssl_cert")
      [ -z "$ssl_key" ] || LS_ARGS+=("--ssl-key=$ssl_key")
      ;;
    link)
      LS_MUTATES=1; LS_EXTERNAL=1; LS_BACKUP=1; LS_LABEL='link QUIC.cloud account'
      email=''; key_env=''
      for x in "$@"; do
        case "$x" in
          --email=*) email=${x#--email=} ;;
          --api-key-env=*) key_env=${x#--api-key-env=} ;;
          --api-key=*) fail_usage 'Do not place QUIC.cloud API keys in shell history. Use --api-key-env=ENV_NAME.' ;;
          *) fail_usage "Unsupported link argument: $x" ;;
        esac
      done
      [ -n "$email" ] || fail_usage 'online link requires --email=EMAIL.'
      case "$key_env" in *[!A-Za-z0-9_]*|'') fail_usage 'online link requires --api-key-env=ENV_NAME.' ;; esac
      [[ "$key_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail_usage "Invalid environment reference."; [ -n "${!key_env:-}" ] || fail_usage "Environment variable $key_env is empty."
      LS_ARGS=("--email=$email"); LS_SECRET_ENV="$key_env"; LS_SECRET_FIELD=api-key
      ;;
    *) fail_usage 'Unknown online action.' ;;
  esac
}

_parse_debug() {
  LS_FAMILY=debug; LS_SUB="${1:-}"; [ "$#" -gt 0 ] && shift || true
  [ "$LS_SUB" = send ] && [ "$#" -eq 0 ] || fail_usage 'debug supports only: send.'
  LS_MUTATES=1; LS_EXTERNAL=1; LS_LABEL='send LiteSpeed environment report to support'
}

_parse_crawler() {
  LS_FAMILY=crawler; LS_SUB="${1:-}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    list|l) LS_SUB=list; [ "$#" -eq 0 ] || fail_usage 'crawler list takes no arguments.'; LS_LABEL='list crawlers' ;;
    enable|disable) [ "$#" -eq 1 ] && _is_uint "$1" || fail_usage "crawler $LS_SUB requires numeric crawler ID."; LS_ARGS=("$1"); LS_MUTATES=1; LS_BACKUP=1; LS_LABEL="$LS_SUB crawler $1" ;;
    run|r) LS_SUB=run; [ "$#" -eq 0 ] || fail_usage 'crawler run takes no arguments.'; LS_MUTATES=1; LS_LABEL='run crawler' ;;
    reset) [ "$#" -eq 0 ] || fail_usage 'crawler reset takes no arguments.'; LS_MUTATES=1; LS_LABEL='reset crawler position' ;;
    *) fail_usage 'Unknown crawler action.' ;;
  esac
}

_parse_database() {
  LS_FAMILY=database; LS_SUB="${1:-status}"; [ "$#" -gt 0 ] && shift || true
  case "$LS_SUB" in
    status) [ "$#" -eq 0 ] || fail_usage 'database status takes no arguments.'; LS_LABEL='database command status'; return ;;
    clear_posts|clear-posts) LS_SUB=clear_posts ;;
    clear_comments|clear-comments) LS_SUB=clear_comments ;;
    clear_trackbacks|clear-trackbacks) LS_SUB=clear_trackbacks ;;
    clear_transients|clear-transients) LS_SUB=clear_transients ;;
    optimize_tables|optimize-tables) LS_SUB=optimize_tables ;;
    optimize_all|optimize-all|optimize) LS_SUB=optimize_all ;;
    *) fail_usage 'Unknown database action.' ;;
  esac
  [ "$#" -le 1 ] || fail_usage 'Database action accepts only optional --blog=ID after PressGarden target parsing. Select a website with a positional target or --target SITE.'
  if [ "$#" -eq 1 ]; then case "$1" in --blog=*) LS_DB_BLOG=${1#--blog=} ;; *) fail_usage 'Use --blog=ID for multisite database actions.' ;; esac; _is_uint "$LS_DB_BLOG" || fail_usage 'Database blog ID must be numeric.'; LS_ARGS=(blog "$LS_DB_BLOG"); fi
  LS_MUTATES=1; LS_LABEL="database $LS_SUB"
}

case "$AREA" in
  help|-h|--help) usage; exit 0 ;;
  status) [ "$#" -eq 0 ] || fail_usage 'litespeed status takes no arguments.' ;;
  option) _parse_option "$@" ;;
  purge) _parse_purge "$@" ;;
  presets|preset) AREA=presets; _parse_presets "$@" ;;
  image) _parse_image "$@" ;;
  online) _parse_online "$@" ;;
  debug) _parse_debug "$@" ;;
  crawler) _parse_crawler "$@" ;;
  database|db) AREA=database; _parse_database "$@" ;;
  *) fail_usage 'Unknown LiteSpeed area.' ;;
esac

_status() {
  local site label version family supported failed=0 skipped=0 active=0 fam_ok total=8
  require_wp; discover_sites
  printf 'LiteSpeed Cache fleet status — %s discovered WordPress installation(s)\n\n' "${#WP_SITES[@]}"
  for site in "${WP_SITES[@]}"; do
    label=$(site_label_from_root "$site")
    if ! _wp_bootstrap_ok "$site"; then printf '  ✖ %-34s ERROR  WordPress/WP-CLI bootstrap failed\n' "$label"; failed=$((failed+1)); continue; fi
    if ! _lscwp_installed "$site"; then printf '  - %-34s SKIP   LiteSpeed Cache not installed\n' "$label"; skipped=$((skipped+1)); continue; fi
    if ! _lscwp_active "$site"; then printf '  - %-34s SKIP   LiteSpeed Cache installed but inactive\n' "$label"; skipped=$((skipped+1)); continue; fi
    version=$(_lscwp_version "$site" || printf unknown); supported=0
    for family in option purge presets image online debug crawler database; do _family_available "$site" "$family" && supported=$((supported+1)); done
    fam_ok="$supported/$total command families"
    active=$((active+1))
    printf '  ✓ %-34s ACTIVE v%s • %s' "$label" "$version" "$fam_ok"
    _is_multisite "$site" && printf ' • multisite'
    printf '\n'
  done
  printf '\nSummary: active %s • skipped %s • errors %s\n' "$active" "$skipped" "$failed"
  [ "$failed" -eq 0 ] || return 2
}

_database_status() {
  local site label row state detail ready=0 skipped=0 failed=0
  require_wp; discover_sites
  printf 'LiteSpeed database command status — %s discovered WordPress installation(s)\n\n' "${#WP_SITES[@]}"
  for site in "${WP_SITES[@]}"; do
    label=$(site_label_from_root "$site"); row=$(_preflight "$site"); IFS=$'\t' read -r state detail <<< "$row"
    case "$state" in READY) ready=$((ready+1)); printf '  ✓ %-34s READY  %s' "$label" "$detail"; _is_multisite "$site" && printf ' • multisite'; printf '\n' ;; SKIP) skipped=$((skipped+1)); printf '  - %-34s SKIP   %s\n' "$label" "$detail" ;; *) failed=$((failed+1)); printf '  ✖ %-34s ERROR  %s\n' "$label" "$detail" ;; esac
  done
  printf '\nSummary: ready %s • skipped %s • errors %s\n' "$ready" "$skipped" "$failed"
  [ "$failed" -eq 0 ] || return 2
}

_execute() {
  local site label row state detail ready=0 skipped=0 preflight_failed=0 ok=0 failed=0 out rc backup export_file export_root
  local -a eligible=()
  require_wp; discover_sites
  printf 'LiteSpeed action: %s\n' "$LS_LABEL"
  printf 'Scope: %s discovered WordPress installation(s)\n\n' "${#WP_SITES[@]}"
  for site in "${WP_SITES[@]}"; do
    label=$(site_label_from_root "$site"); row=$(_preflight "$site"); IFS=$'\t' read -r state detail <<< "$row"
    case "$state" in READY) ready=$((ready+1)); eligible+=("$site"); printf '  ✓ %-34s READY  %s\n' "$label" "$detail" ;; SKIP) skipped=$((skipped+1)); printf '  - %-34s SKIP   %s\n' "$label" "$detail" ;; *) preflight_failed=$((preflight_failed+1)); printf '  ✖ %-34s ERROR  %s\n' "$label" "$detail" ;; esac
  done
  [ "${#eligible[@]}" -gt 0 ] || { printf '\nNo eligible LiteSpeed Cache sites found.\n'; [ "$preflight_failed" -eq 0 ] || return 2; return 0; }

  if [ "$AREA" = option ] && [ "$LS_SUB" = export ] && [ -n "$LS_USER_EXPORT" ] && [ "${#eligible[@]}" -gt 1 ]; then
    printf '\nRefusing one --filename path for multiple sites because exports would overwrite each other. Target one site or omit --filename for private per-site exports.\n' >&2
    return 2
  fi

  if [ "$LS_MUTATES" = 1 ]; then pg_mutation_preflight || return 2; _confirm "${#eligible[@]}" "$LS_LABEL" || return 1; fi

  for site in "${eligible[@]}"; do
    pg_unlock_site
    if [ "$LS_MUTATES" = 1 ]; then pg_lock_site "$site" || { failed=$((failed+1)); continue; }; fi
    label=$(site_label_from_root "$site"); backup=''
    if [ "$LS_BACKUP" = 1 ]; then
      backup=$(_backup_options "$site" "$label") || { printf '  ✖ %-34s FAILED  could not create private LiteSpeed option backup; unchanged\n' "$label"; failed=$((failed+1)); continue; }
      printf '  ℹ %-34s BACKUP %s\n' "$label" "$backup"
    fi

    if [ "$LS_FAMILY" = database ]; then
      pg_database_backup "$site" || { failed=$((failed+1)); continue; }
    fi
    out=$(tmpf); rc=0
    if [ "$AREA" = option ] && [ "$LS_SUB" = export ]; then
      if [ -n "$LS_USER_EXPORT" ]; then export_file="$LS_USER_EXPORT"; else
        export_root=$(pg_safe_backup_dir "$site" litespeed-exports) || { rm -f "$out"; printf '  ✖ %-34s FAILED  cannot create export directory\n' "$label"; failed=$((failed+1)); continue; }
        export_file="$export_root/$(_safe_label "$label").txt"
      fi
      case "$export_file" in /*) :;; *) export_file="$PWD/$export_file";; esac
      if [ -e "$export_file" ] || [ -L "$export_file" ]; then
        printf 'FAILED: existing export destination refused.\n' >&2; rm -f "$out"; failed=$((failed+1)); continue
      fi
      if ! php -r 'require $argv[1];$f=$argv[2];if($f[0]!=="/")$f=getcwd()."/".$f;pg_ops_dir(dirname($f));pg_ops_path($argv[4]);if(strpos($f,rtrim($argv[4],"/")."/")!==0||strpos($f,$argv[3]."/")===0)exit(2);' "$PRESSGARDEN_DIR/lib/ops-safety.php" "$export_file" "$site" "$PRESSGARDEN_STATE_DIR"; then rm -f "$out"; failed=$((failed+1)); continue; fi
      (umask 077; _ls_standard "$site" litespeed-option export "--filename=$export_file" >"$out" 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || php -r 'require $argv[1];$s=pg_ops_regular($argv[2]);if(!$s["size"])exit(2);' "$PRESSGARDEN_DIR/lib/ops-safety.php" "$export_file" || rc=2
      [ "$rc" -ne 0 ] || chmod 600 "$export_file" 2>/dev/null || true
    elif [ -n "$LS_SECRET_ENV" ]; then
      _ls_standard "$site" eval-file "$PRESSGARDEN_DIR/lib/litespeed-secret-command.php" "$LS_SUB" "$LS_SECRET_FIELD" "$LS_SECRET_ENV" "${LS_ARGS[@]#--}" >"$out" 2>&1 || rc=$?
    elif [ "$LS_FAMILY" = database ]; then
      _ls_database "$site" "$LS_SUB" "${LS_ARGS[@]}" >"$out" 2>&1 || rc=$?
    else
      _ls_standard "$site" "litespeed-$LS_FAMILY" "$LS_SUB" "${LS_ARGS[@]}" >"$out" 2>&1 || rc=$?
    fi

    if [ "$rc" -eq 0 ] && [ "$AREA:$LS_SUB" = option:set ]; then
      verify=$(tmpf)
      if ! _ls_standard "$site" litespeed-option get "${LS_ARGS[0]}" > "$verify" 2>/dev/null || ! printf '%s' "${LS_ARGS[1]}" | php "$PRESSGARDEN_DIR/lib/litespeed-output.php" verify "$verify"; then
        printf '  UNVERIFIED %s: requested option does not match readback; recovery export retained.\n' "$label"; rc=2
      else printf '  VERIFIED %s: option readback matches requested value.\n' "$label"; fi
      rm -f "$verify"
    fi
    if [ "$rc" -eq 0 ]; then
      ok=$((ok+1)); printf '  ✓ %-34s COMMAND COMPLETED' "$label"
      if [ "$AREA" = option ] && [ "$LS_SUB" = export ]; then printf '  %s' "$export_file"; fi
      printf '\n'
      if [ "$LS_OUTPUT" = 1 ] && ! { [ "$AREA" = option ] && [ "$LS_SUB" = export ]; }; then _show_output "$out" "$([ "$LS_MUTATES" = 1 ] && printf bounded || printf full)"; fi
    else
      failed=$((failed+1)); printf '  ✖ %-34s FAILED  exit %s\n' "$label" "$rc"; _show_output "$out" bounded
    fi
    rm -f "$out"
  done
  pg_unlock_site
  printf '\nSummary: success %s • skipped %s • preflight errors %s • execution failures %s\n' "$ok" "$skipped" "$preflight_failed" "$failed"
  [ "$preflight_failed" -eq 0 ] && [ "$failed" -eq 0 ] || return 2
}

if [ "$AREA" = status ]; then _status
elif [ "$AREA" = database ] && [ "$LS_SUB" = status ]; then _database_status
else _execute
fi
