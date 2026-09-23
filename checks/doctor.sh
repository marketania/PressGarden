#!/usr/bin/env bash
NAME=doctor; DESC='Local installation, dependency and target-discovery health'
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
failed=0
printf 'PressGarden doctor • %s\n' "$PRESSGARDEN_VERSION"
for executable in bash php find sort stat mktemp tar; do
  if command -v "$executable" >/dev/null 2>&1; then printf '  ✓ %s available\n' "$executable"
  else printf '  ✖ %s missing\n' "$executable"; failed=1; fi
done
if command -v wp >/dev/null 2>&1; then printf '  ✓ WP-CLI available\n'; else printf '  ✖ WP-CLI missing; WordPress operations are unavailable\n'; failed=1; fi
if [ "${PG_DISCOVERY_FAILED:-0}" -ne 0 ]; then printf '  ✖ Discovery incomplete\n'; failed=1; fi
printf '  Selected installations: %s\n  State: %s\n  Cache: %s\n' "${#SCAN_ROOTS[@]}" "$PRESSGARDEN_STATE_DIR" "$PRESSGARDEN_CACHE_DIR"
printf '  Config is trusted shell code: %s\n' "$PRESSGARDEN_CONFIG_FILE"
printf '  No websites, PHP settings, cache or databases were changed.\n'
[ "$failed" -eq 0 ] || exit 2
