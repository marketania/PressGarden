#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/site" "$T/state"; printf '<?php\n' > "$T/site/wp-config.php"; chmod 700 "$T/state"
export PRESSGARDEN_DIR="$REPO" PRESSGARDEN_STATE_DIR="$T/state"
. "$REPO/lib/operations.sh"
file=$(php "$REPO/lib/ops-safety.php" lock-file "$T/state" "$T/site")
pg_lock_site "$T/site"
# Closing the inherited FD before a second process recreates the real process boundary.
set +e
bash -c 'exec 8>&-; . "$PRESSGARDEN_DIR/lib/operations.sh"; pg_lock_site "$1"' _ "$T/site" > "$T/busy" 2>&1
rc=$?;set -e; [ "$rc" -eq 2 ];grep -q 'busy' "$T/busy"
pg_unlock_site
bash -c '. "$PRESSGARDEN_DIR/lib/operations.sh"; pg_lock_site "$1"; pg_unlock_site' _ "$T/site"
rm "$file";echo KEEP > "$T/other";ln -s "$T/other" "$file"
if pg_lock_site "$T/site" > /dev/null 2>&1;then exit 1;fi
[ "$(cat "$T/other")" = KEEP ]
printf 'Writer locks: independent process contention, release and symlink refusal PASS\n'
