#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
action="${1:-status}"; shift || true
network=0; blog=''
for arg in "$@"; do
  case "$arg" in
    --network) [ "$network" = 0 ] && [ -z "$blog" ] || exit 2; network=1;;
    --blog=*) [ "$network" = 0 ] && [ -z "$blog" ] || exit 2; blog=${arg#*=}; [[ "$blog" =~ ^[1-9][0-9]{0,9}$ ]] || exit 2;;
    *) printf 'Unknown cache option: %s. clear accepts --network or --blog=ID.\n' "$arg" >&2; exit 2;;
  esac
done
if [ "$action" != clear ] && { [ "$network" != 0 ] || [ -n "$blog" ]; }; then printf 'Cache scope selectors apply only to clear.\n' >&2; exit 2; fi
case "$action" in
  status) printf 'Provider: LiteSpeed Cache. Below is configured state, not proof of an HTTP cache HIT or backend connectivity.\n'; exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" option get cache;;
  clear)
    if [ -n "$blog" ]; then exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" purge blog "$blog"; fi
    scope=(); [ "$network" = 0 ] || scope=(--network)
    exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" purge all "${scope[@]}";;
  enable) exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" option set cache true;;
  disable) exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" option set cache false;;
  *) exit 2;;
esac
