#!/usr/bin/env bash
# Terminal cleanup preview asks "Clean now?" per category; default No.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v script >/dev/null 2>&1 || { printf 'Cleanup prompt: SKIP (no script(1) pty helper)\n'; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
p="$T/sites/example.com/public_html"; mkdir -p "$p/wp-admin" "$p/wp-content" "$p/wp-includes"
touch "$p/wp-load.php" "$p/wp-settings.php"; printf '<?php $wp_version="7.1";\n' > "$p/wp-includes/version.php"; printf '<?php\n' > "$p/wp-config.php"
seed(){
  printf 'old harmless metadata\n' > "$p/.DS_Store"; touch -d '90 days ago' "$p/.DS_Store"
  printf 'old rotated\n' > "$p/debug.log.1"; touch -d '90 days ago' "$p/debug.log.1"
}
export PRESSGARDEN_SCAN_ROOT="$T/sites" PRESSGARDEN_STATE_DIR="$T/state" PRESSGARDEN_CACHE_DIR="$T/cache" PRESSGARDEN_CONFIG_FILE="$T/no-config" PRESSGARDEN_PROGRESS=0 REPO
# Run in a pty, feeding answers one per line.
tty_run(){ local answers=$1; shift; printf '%b' "$answers" | script -qec "bash \"\$REPO/pressgarden\" $*" /dev/null > "$T/out" 2>&1 || true; }
count(){ grep -c 'Clean now?' "$T/out" || true; }

# Enter (default) skips both file categories; nothing changes.
seed; PRESSGARDEN_INTERACTIVE=1 tty_run '\n\n' cleanup --files --logs example.com
[ "$(count)" -eq 2 ]; [ -f "$p/.DS_Store" ]; [ -f "$p/debug.log.1" ]; grep -q 'PREVIEW:' "$T/out"
grep -q 'Disposable files: 1 files' "$T/out"; grep -q 'Old rotated logs: 1 files' "$T/out"

# Yes to disposable files (then the per-site confirmation), no to logs.
seed; PRESSGARDEN_INTERACTIVE=1 tty_run 'y\ny\nn\n' cleanup --files --logs example.com
[ "$(count)" -eq 2 ]; [ ! -f "$p/.DS_Store" ]; [ -f "$p/debug.log.1" ]; grep -q COMPLETE "$T/out"
find "$T/state/backups/file-cleanup" -name manifest.json | grep -q .

# Declining the inner per-site confirmation keeps the files.
seed; PRESSGARDEN_INTERACTIVE=1 tty_run 'n\ny\nn\n' cleanup --files --logs example.com
[ -f "$p/.DS_Store" ]; [ -f "$p/debug.log.1" ]

# No prompt without a terminal, under PRESSGARDEN_INTERACTIVE=0, or for status.
seed; PRESSGARDEN_INTERACTIVE=1 bash "$REPO/pressgarden" cleanup --files example.com < /dev/null > "$T/out" 2>&1 || true
[ "$(count)" -eq 0 ]; [ -f "$p/.DS_Store" ]
PRESSGARDEN_INTERACTIVE=0 tty_run 'y\ny\n' cleanup --files example.com
[ "$(count)" -eq 0 ]; [ -f "$p/.DS_Store" ]
PRESSGARDEN_INTERACTIVE=1 tty_run 'y\ny\n' cleanup status --files example.com
[ "$(count)" -eq 0 ]; [ -f "$p/.DS_Store" ]
printf 'Cleanup prompt: per-category terminal prompt, default No, guarded execute on yes, no prompt unattended PASS\n'
