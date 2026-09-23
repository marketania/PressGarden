#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
product=$(cat "$REPO/PRODUCT"); program=${product,,}; prefix=${product^^}
for name in a.example b.example; do
 p="$T/sites/$name/public_html"; mkdir -p "$p/wp-admin" "$p/wp-content" "$p/wp-includes"
 touch "$p/wp-load.php" "$p/wp-settings.php"; printf '<?php $wp_version="7.1";\n' > "$p/wp-includes/version.php"; printf '<?php\n' > "$p/wp-config.php"
done
mkdir -p "$T/bin"
cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS"
exit 95
WP
chmod +x "$T/bin/wp"
export PATH="$T/bin:$PATH" TEST_CALLS="$T/calls"
export "${prefix}_SCAN_ROOT=$T/sites" "${prefix}_CONFIG_FILE=$T/no-config" "${prefix}_STATE_DIR=$T/state" "${prefix}_CACHE_DIR=$T/cache" "${prefix}_INTERACTIVE=0" "${prefix}_PROGRESS=0"
# Foreign operational names and generic report aliases cannot leak across products.
foreign="PRESS""WARDEN"
export "${foreign}_STATE_DIR=$T/foreign-state" "${foreign}_SCAN_ROOT=$T/foreign-sites" REPORTS="$T/foreign-reports" QUARANTINE="$T/foreign-quarantine"
run(){ bash "$REPO/$program" "$@"; }
run sites > "$T/sites.out"; grep -q a.example "$T/sites.out"; grep -q b.example "$T/sites.out"
if [ "$product" = PressHarden ]; then tests=("lock" "unlock" "lock-status" "status"); else tests=("status" "cleanup preview" "db check" "cache clear" "litespeed-db optimize"); fi
for spec in "${tests[@]}"; do
 read -r -a args <<< "$spec"
 for target in missing.example ''; do
   : > "$T/calls"; set +e; run "${args[@]}" "$target" > "$T/out" 2>&1; rc=$?; set -e
   [ "$rc" -eq 2 ]; [ ! -s "$T/calls" ]
 done
done
ln -s "$T/sites/b.example/public_html" "$T/linked"
for spec in "${tests[@]}"; do read -r -a args <<< "$spec"; if run "${args[@]}" "$T/linked" > /dev/null 2>&1; then exit 1; fi; done
[ ! -e "$T/foreign-state" ]; [ ! -e "$T/foreign-reports" ]; [ ! -e "$T/foreign-quarantine" ]
# Independent runtime must not import an old scanner, sibling, or intelligence module.
! grep -R -E "${foreign}_|lib/(intel|quarantine|remediation)\.sh" "$REPO/lib" "$REPO/checks" "$REPO/$program" "$REPO/config"
printf '%s targeting/namespace boundaries PASS\n' "$product"
