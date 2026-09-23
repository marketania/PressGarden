#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
p="$T/sites/example.com/public_html"; mkdir -p "$p/wp-admin" "$p/wp-content" "$p/wp-includes" "$T/bin"
touch "$p/wp-load.php" "$p/wp-settings.php"; printf '<?php $wp_version="7.1";\n' > "$p/wp-includes/version.php"; printf '<?php\n' > "$p/wp-config.php"
cat > "$T/bin/wp" <<'WP'
#!/usr/bin/env bash
set -eu
args=();p=''
for a in "$@"; do case "$a" in --path=*)p=${a#*=};; --skip-*|--no-color) :;; *)args+=("$a");; esac; done
set -- "${args[@]}"; [ -n "$p" ] || p="$PWD"
case "$1" in
 core) if [ "${3:-}" = --network ]; then exit 1; fi;;
 plugin) if [ "$2" = get ]; then echo 7.5; fi;;
 help) exit 0;;
 eval-file) if [ "${3:-}" = plan ]; then echo wp_options,wp_posts; else echo MUTATION >> "$TEST_MUTATIONS"; fi;;
 db) [ "$2" = export ] || exit 2; [ ! -e "$TEST_FAIL_BACKUP" ] || exit 40; printf '%s\n' '-- isolated fixture SQL dump only' > "$3";;
 litespeed-database) echo MUTATION >> "$TEST_MUTATIONS";;
 *) exit 95;;
esac
WP
chmod +x "$T/bin/wp"
export PATH="$T/bin:$PATH" PRESSGARDEN_SCAN_ROOT="$T/sites" PRESSGARDEN_STATE_DIR="$T/state" PRESSGARDEN_CACHE_DIR="$T/cache" PRESSGARDEN_CONFIG_FILE="$T/no-config" PRESSGARDEN_INTERACTIVE=0 PRESSGARDEN_PROGRESS=0
export TEST_MUTATIONS="$T/mutations" TEST_FAIL_BACKUP="$T/backup-failure"
run(){ bash "$REPO/pressgarden" "$@"; }
touch "$TEST_FAIL_BACKUP"
for action in 'db optimize' 'db repair' 'db cleanup'; do
 read -r -a args <<< "$action"; [ "$action" != 'db cleanup' ] || args+=(--execute)
 set +e; run "${args[@]}" example.com > "$T/out" 2>&1; rc=$?; set -e
 [ "$rc" -eq 2 ]; [ ! -e "$TEST_MUTATIONS" ]
done
set +e; run litespeed database clear-posts example.com > "$T/ls" 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ]; [ ! -e "$TEST_MUTATIONS" ]
rm "$TEST_FAIL_BACKUP"
run db optimize example.com > "$T/pass"
[ -f "$TEST_MUTATIONS" ]; find "$T/state/backups/database" -name '*.sha256' | grep -q .
# Local state inside a website must not be used as a backup destination.
rm "$TEST_MUTATIONS"
if PRESSGARDEN_STATE_DIR="$p/private" run db optimize example.com > /dev/null 2>&1; then exit 1; fi
[ ! -e "$TEST_MUTATIONS" ]
printf 'DB backup gates: native repair/optimize/cleanup and LiteSpeed, no mutation on failed export, private state isolation PASS\n'
