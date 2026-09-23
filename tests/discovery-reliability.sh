#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/pressgarden-discovery.XXXXXX")
trap 'rm -rf "$T"' EXIT
ROOT="$T/sites"; STATE="$T/state"; CACHE="$T/cache"; mkdir -p "$ROOT/good.com/public_html" "$STATE" "$CACHE" "$T/bin"
make_wp() {
  local p="$1"; mkdir -p "$p/wp-admin" "$p/wp-content" "$p/wp-includes"
  : > "$p/wp-load.php"; : > "$p/wp-settings.php"; printf '<?php $wp_version="7.1";\n' > "$p/wp-includes/version.php"
}
make_wp "$ROOT/good.com/public_html"
cat > "$T/bin/find" <<'FIND'
#!/usr/bin/env bash
set -u
marker="${PG_TEST_FIND_MARKER:-}"
[ -z "$marker" ] || : > "$marker"
/usr/bin/find "$@"
rc=$?
if [ "${PG_TEST_FAIL_DISCOVERY_FIND:-0}" = 1 ]; then
  for a in "$@"; do [ "$a" != wp-settings.php ] || exit 1; done
fi
exit "$rc"
FIND
chmod +x "$T/bin/find"

env_common=(ROOT="$ROOT" PRESSGARDEN_SCAN_ROOT="$ROOT" PRESSGARDEN_CONFIG_FILE="$T/no-config" PRESSGARDEN_STATE_DIR="$STATE" PRESSGARDEN_CACHE_DIR="$CACHE" PRESSGARDEN_DISCOVERY_CACHE_TTL=300 PRESSGARDEN_NOCOLOR=1)

# A traversal command that yields a valid site but exits nonzero is partial discovery, never clean.
set +e
out=$(env "${env_common[@]}" PATH="$T/bin:$PATH" PG_TEST_FAIL_DISCOVERY_FIND=1 bash -c '. "$1/lib/env-discovery.sh"; printf "%s|%s|%s\n" "$PG_DISCOVERY_FAILED" "${#SCAN_ROOTS[@]}" "${SCAN_ROOTS[0]:-}"' _ "$REPO" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ]; case "$out" in 1\|1\|"$ROOT/good.com/public_html"*) ;; *) printf '%s\n' "$out" >&2; exit 1 ;; esac
[ ! -e "$CACHE/discovery.tsv" ]

# Direct checks retain validated-site output but finish INCOMPLETE.
cat > "$T/direct-check.sh" <<'CHECK'
#!/usr/bin/env bash
NAME=discovery-test; DESC='synthetic discovery verdict'; SCAN_DOES='test'; SCAN_WHY='test'
. "$1/lib/_lib.sh"
main() { banner; sec 'Synthetic clean section'; f=$(tmpf); : > "$f"; report "$f" info 'synthetic clean'; finish; }
run_logged discovery-test
CHECK
set +e
env "${env_common[@]}" PATH="$T/bin:$PATH" PG_TEST_FAIL_DISCOVERY_FIND=1 bash "$T/direct-check.sh" "$REPO" > "$T/direct.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]; grep -q 'INCOMPLETE' "$T/direct.out"; ! grep -q '^  CLEAN' "$T/direct.out"

# Generate a good cache first.
env "${env_common[@]}" PRESSGARDEN_DISCOVERY_REFRESH=1 bash -c '. "$1/lib/env-discovery.sh"; [ "$PG_DISCOVERY_FAILED" -eq 0 ]; [ "${#SCAN_ROOTS[@]}" -eq 1 ]' _ "$REPO"
[ -f "$CACHE/discovery.tsv" ]; [ ! -L "$CACHE/discovery.tsv" ]; [ "$(stat -c %a "$CACHE/discovery.tsv")" = 600 ]
meta=$(head -n 1 "$CACHE/discovery.tsv")

# A cache path outside ROOT must never broaden the target; it is rejected and rebuilt live.
OUTSIDE="$T/outside.com/public_html"; make_wp "$OUTSIDE"
{ printf '%s\n' "$meta"; printf 'ROOT\t%s\nTREE\t%s\nDOMAIN\toutside.com\n' "$OUTSIDE" "$OUTSIDE"; } > "$CACHE/discovery.tsv"
marker="$T/find-used"; rm -f "$marker"
out=$(env "${env_common[@]}" PATH="$T/bin:$PATH" PG_TEST_FIND_MARKER="$marker" bash -c '. "$1/lib/env-discovery.sh"; printf "%s|%s\n" "$PG_DISCOVERY_FAILED" "${SCAN_ROOTS[0]:-}"' _ "$REPO")
[ -f "$marker" ]; [ "$out" = "0|$ROOT/good.com/public_html" ]

# Symlinked cache files are never trusted or followed.
poison="$T/poison.tsv"; { printf '%s\n' "$meta"; printf 'ROOT\t%s\n' "$OUTSIDE"; } > "$poison"
rm -f "$CACHE/discovery.tsv"; ln -s "$poison" "$CACHE/discovery.tsv"; marker="$T/find-used-2"; rm -f "$marker"
out=$(env "${env_common[@]}" PATH="$T/bin:$PATH" PG_TEST_FIND_MARKER="$marker" bash -c '. "$1/lib/env-discovery.sh"; printf "%s|%s\n" "$PG_DISCOVERY_FAILED" "${SCAN_ROOTS[0]:-}"' _ "$REPO")
[ -f "$marker" ]; [ "$out" = "0|$ROOT/good.com/public_html" ]; [ -L "$CACHE/discovery.tsv" ]

# Oversized/corrupt caches are ignored rather than parsed into shell arrays.
rm -f "$CACHE/discovery.tsv"; { printf '%s\n' "$meta"; head -c 4195000 /dev/zero | tr '\0' X; } > "$CACHE/discovery.tsv"
marker="$T/find-used-3"; rm -f "$marker"
out=$(env "${env_common[@]}" PATH="$T/bin:$PATH" PG_TEST_FIND_MARKER="$marker" bash -c '. "$1/lib/env-discovery.sh"; printf "%s|%s\n" "$PG_DISCOVERY_FAILED" "${SCAN_ROOTS[0]:-}"' _ "$REPO")
[ -f "$marker" ]; [ "$out" = "0|$ROOT/good.com/public_html" ]

printf 'Discovery completeness, fail-closed verdicts and cache boundary validation: PASS\n'
