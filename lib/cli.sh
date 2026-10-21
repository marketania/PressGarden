# Terminal and configuration helpers shared by the CLI and operation dashboards.
# This file has no discovery, state-directory or provider side effects.

# Keep exported overrides byte-for-byte, including newline-separated exclusions.
# Only names pass through line-oriented output; values come from Bash variables.
pg_cli_save_environment() {
  local key names
  PG_CLI_ENV_KEYS=(); PG_CLI_ENV_VALUES=()
  names=$(compgen -e)
  while IFS= read -r key; do
    [[ "$key" =~ ^PRESSGARDEN_[A-Za-z0-9_]*$ ]] || continue
    [ "${!key+x}" = x ] || continue
    PG_CLI_ENV_KEYS+=("$key"); PG_CLI_ENV_VALUES+=("${!key}")
  done <<< "$names"
}

pg_cli_restore_environment() {
  local i
  for i in "${!PG_CLI_ENV_KEYS[@]}"; do
    if ! printf -v "${PG_CLI_ENV_KEYS[$i]}" '%s' "${PG_CLI_ENV_VALUES[$i]}" || ! export "${PG_CLI_ENV_KEYS[$i]}"; then
      printf 'Cannot restore exported PressGarden setting %s; operation refused.\n' "${PG_CLI_ENV_KEYS[$i]}" >&2
      return 2
    fi
  done
  unset PG_CLI_ENV_KEYS PG_CLI_ENV_VALUES
}

pg_color_init() {
  local mode="${PRESSGARDEN_COLOR:-auto}" enabled=0
  case "$mode" in auto|always|never) :;; *) printf 'Use --color=auto|always|never.\n' >&2; return 2;; esac
  if [ -n "${NO_COLOR:-}${PRESSGARDEN_NOCOLOR:-}" ]; then enabled=0
  elif [ "$mode" = always ]; then enabled=1
  elif [ "$mode" = auto ] && [ "${TERM:-dumb}" != dumb ]; then
    { [ -t 1 ] || { [ -n "${PRESSGARDEN_FORCE_COLOR:-}" ] && [ "${PRESSGARDEN_FORCE_COLOR:-}" != 0 ]; }; } && enabled=1
  fi
  B=''; D=''; U=''; R=''; G=''; Y=''; BL=''; M=''; C=''; WHT=''; X=''
  if [ "$enabled" = 1 ]; then
    B=$'\033[1m'; D=$'\033[2m'; U=$'\033[4m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; BL=$'\033[34m'; M=$'\033[35m'; C=$'\033[36m'; WHT=$'\033[37m'; X=$'\033[0m'
  fi
}
pg_heading() { printf '\n%s%s%s%s\n' "$B" "$C" "$1" "$X"; }
pg_display_text() {
  php -r '$v=preg_replace("/[\\p{Cc}\\p{Cf}]/u","?",$argv[1]);echo $v??"(unreadable text)";' "$1"
}
pg_badge() {
  local color="$C"
  case "$1" in CLEAR|OK|COMPLETE) color="$G";; READY|REVIEW|PARTIAL) color="$Y";; INCOMPLETE|FAILED|REFUSED) color="$R";; esac
  printf '%s%s%-10s%s' "$B" "$color" "$1" "$X"
}
