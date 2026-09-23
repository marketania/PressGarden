#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
[ "$#" -eq 1 ] || { printf 'Cache supports only the built-in LiteSpeed provider; additional arguments are unsupported.\n' >&2; exit 2; }
case "$1" in
  status) printf 'Provider: LiteSpeed Cache. Below is configured state, not proof of an HTTP cache HIT or backend connectivity.\n'; exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" option get cache;;
  clear) exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" purge all;;
  enable) exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" option set cache true;;
  disable) exec bash "$PRESSGARDEN_DIR/checks/litespeed.sh" option set cache false;;
  *) exit 2;;
esac
