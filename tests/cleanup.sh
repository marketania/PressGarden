#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for domain in example.com other.com; do
 p="$T/sites/$domain/public_html"; mkdir -p "$p/wp-admin" "$p/wp-content" "$p/wp-includes"
 touch "$p/wp-load.php" "$p/wp-settings.php"; printf '<?php $wp_version="7.1";\n' > "$p/wp-includes/version.php"; printf '<?php\n' > "$p/wp-config.php"
 printf 'old harmless metadata\n' > "$p/.DS_Store"; touch -d '90 days ago' "$p/.DS_Store"
done
export PRESSGARDEN_SCAN_ROOT="$T/sites" PRESSGARDEN_STATE_DIR="$T/state" PRESSGARDEN_CACHE_DIR="$T/cache" PRESSGARDEN_CONFIG_FILE="$T/no-config" PRESSGARDEN_INTERACTIVE=0 PRESSGARDEN_PROGRESS=0
run(){ bash "$REPO/pressgarden" "$@"; }
p="$T/sites/example.com/public_html"
printf 'live log\n' > "$p/debug.log"; touch -d '90 days ago' "$p/debug.log"
printf 'old rotated\n' > "$p/debug.log.1"; touch -d '90 days ago' "$p/debug.log.1"
run cleanup example.com > "$T/preview"; [ -f "$p/.DS_Store" ]; grep -q 'PREVIEW:' "$T/preview"
run cleanup execute example.com > "$T/execute"; [ ! -f "$p/.DS_Store" ]; [ -f "$p/debug.log" ]; [ -f "$p/debug.log.1" ]; [ -f "$T/sites/other.com/public_html/.DS_Store" ]
grep -q 'Files removed: 1' "$T/execute"; find "$T/state/backups/file-cleanup" -name manifest.json | grep -q .
run cleanup execute example.com --logs > "$T/logs"; [ ! -f "$p/debug.log.1" ]; [ -f "$p/debug.log" ]
# Executable-looking content is not deleted even under a metadata name.
printf '<?php /* inert suspicious fixture */\n' > "$p/.DS_Store"; touch -d '90 days ago' "$p/.DS_Store"
set +e; run cleanup execute example.com > "$T/suspicious"; rc=$?; set -e
[ "$rc" -eq 2 ]; [ -f "$p/.DS_Store" ]; grep -q STOPPED "$T/suspicious"
rm "$p/.DS_Store"; ln -s "$T/sites/other.com/public_html/.DS_Store" "$p/.DS_Store"
run cleanup execute example.com > /dev/null; [ -L "$p/.DS_Store" ]; [ -f "$T/sites/other.com/public_html/.DS_Store" ]
# Explicit development cleanup preserves every live Git tree and application vendor files.
rm "$p/.DS_Store"
echo inert > "$p/.editorconfig"; touch -d '90 days ago' "$p/.editorconfig"
mkdir -p "$p/project/.git" "$p/wp-content/plugins/demo"
for f in "$p/project/.editorconfig" "$p/wp-content/plugins/demo/.gitignore"; do echo inert > "$f";touch -d '90 days ago' "$f";done
run cleanup execute example.com --development > "$T/development"
[ ! -f "$p/.editorconfig" ];[ -f "$p/project/.editorconfig" ];[ -f "$p/wp-content/plugins/demo/.gitignore" ]
ln -s "$T/sites/other.com/public_html/.DS_Store" "$p/.DS_Store"
# Incomplete scan means no deletion; unbounded recursion is not allowed.
rm "$p/.DS_Store"; echo harmless > "$p/.DS_Store"; touch -d '90 days ago' "$p/.DS_Store"
d="$p"; for i in $(seq 1 26); do d="$d/level"; mkdir "$d"; done
if run cleanup execute example.com > /dev/null 2>&1; then exit 1; fi
[ -f "$p/.DS_Store" ]
printf 'File cleanup: preview, target isolation, backups/counts, old rotated logs only, executable/symlink/depth safeguards PASS\n'
