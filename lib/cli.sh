# Small terminal helpers shared by help and operation dashboards.
# This file has no discovery, state-directory or provider side effects.
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
