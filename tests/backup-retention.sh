#!/usr/bin/env bash
# Manual backup retention: preview by default, only complete intact backups,
# newest per site/category kept, exact previewed set and a private prune log.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export PRESSGARDEN_STATE_DIR="$T/state" PRESSGARDEN_CACHE_DIR="$T/cache" PRESSGARDEN_CONFIG_FILE="$T/no-config" PRESSGARDEN_INTERACTIVE=0 HOME="$T/home"
B="$T/state/backups"; mkdir -p "$B/file-cleanup" "$B/database" "$B/litespeed-options" "$T/home"
chmod -R go-rwx "$T/state"
s1=aaaaaaaaaaaa; s2=bbbbbbbbbbbb; r=0123456789abcdef
mk_cleanup() { mkdir "$B/file-cleanup/$1"; printf '{"status":"%s","files":[]}' "$2" > "$B/file-cleanup/$1/manifest.json"; printf 'copy' > "$B/file-cleanup/$1/0000.data"; }
mk_db() { mkdir "$B/database/$1"; printf -- '-- fixture dump\n' > "$B/database/$1/database.sql"; (cd "$B/database/$1" && sha256sum database.sql > database.sql.sha256); }
mk_cleanup "20200101T000000Z-$s1-$r" COMPLETED        # old, complete: eligible
mk_cleanup "20200102T000000Z-$s1-$r" PARTIAL          # old, partial: kept
mk_cleanup "20200103T000000Z-$s1-$r" COMPLETED        # old but newest for s1: kept
mk_cleanup "20200101T000000Z-$s2-$r" COMPLETED        # only backup for s2: kept
mk_db "20200101T000000Z-$s1-$r"                       # old, intact: eligible
mk_db "20200102T000000Z-$s1-$r"; printf 'x' >> "$B/database/20200102T000000Z-$s1-$r/database.sql"  # corrupt: kept
mk_db "$(date -u +%Y%m%dT%H%M%SZ)-$s1-$r"            # fresh newest: not listed
mkdir "$B/litespeed-options/20200101T000000Z-$s1-$r" "$B/litespeed-options/20200102T000000Z-$s1-$r"
run(){ bash "$REPO/pressgarden" "$@"; }
for bad in '' 'prune' 'prune --older-than=0' 'prune --older-than=x' 'prune --older-than=30 --force'; do
  read -r -a args <<< "$bad"
  set +e; run backups "${args[@]}" > "$T/bad" 2>&1; rc=$?; set -e
  [ "$rc" -eq 2 ]
done
run backups prune --older-than=30 > "$T/preview"
grep -q 'Eligible: 2 backup(s)' "$T/preview"
grep -q "PRUNE  database/20200101T000000Z-$s1-$r" "$T/preview"
grep -q "PRUNE  file-cleanup/20200101T000000Z-$s1-$r" "$T/preview"
grep -q "KEEP   file-cleanup/20200102T000000Z-$s1-$r  cleanup status PARTIAL" "$T/preview"
grep -q "KEEP   file-cleanup/20200103T000000Z-$s1-$r  newest backup" "$T/preview"
grep -q "KEEP   file-cleanup/20200101T000000Z-$s2-$r  newest backup" "$T/preview"
grep -q "KEEP   database/20200102T000000Z-$s1-$r  checksum mismatch" "$T/preview"
grep -q "KEEP   litespeed-options/20200101T000000Z-$s1-$r  no completion record" "$T/preview"
[ -d "$B/file-cleanup/20200101T000000Z-$s1-$r" ] && [ -d "$B/database/20200101T000000Z-$s1-$r" ]
# A stale approval is refused before anything is removed.
printf 'database/20200101T000000Z-%s-%s\n' "$s1" "$r" > "$T/stale"; chmod 600 "$T/stale"
set +e; php "$REPO/lib/backup-retention.php" apply "$T/state" 30 "$T/stale" > "$T/stale.out" 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ]; grep -q 'changed since preview' "$T/stale.out"; [ -d "$B/database/20200101T000000Z-$s1-$r" ]
# INTERACTIVE=0 is Garden's documented deliberate unattended authorization.
run backups prune --older-than=30 --apply > "$T/apply"
grep -q 'Backups removed: 2' "$T/apply"
[ ! -e "$B/file-cleanup/20200101T000000Z-$s1-$r" ] && [ ! -e "$B/database/20200101T000000Z-$s1-$r" ]
[ -d "$B/file-cleanup/20200102T000000Z-$s1-$r" ] && [ -d "$B/file-cleanup/20200103T000000Z-$s1-$r" ] && [ -d "$B/database/20200102T000000Z-$s1-$r" ]
! find "$B" -name '.pruning-*' | grep -q .
grep -q "file-cleanup/20200101T000000Z-$s1-$r" "$B/prune-log.tsv"
[ "$(stat -c %a "$B/prune-log.tsv")" = 600 ]
# Without a terminal and without INTERACTIVE=0, nothing is removed.
mk_cleanup "20200101T000000Z-$s1-fedcba9876543210" COMPLETED
set +e; PRESSGARDEN_INTERACTIVE=1 run backups prune --older-than=30 --apply < /dev/null > "$T/notty" 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ]; [ -d "$B/file-cleanup/20200101T000000Z-$s1-fedcba9876543210" ]
printf 'Backup retention preview, completion gate, newest-kept and exact approval: PASS\n'
