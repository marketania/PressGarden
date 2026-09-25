#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
action="${1:-preview}"; shift || true
case "$action" in status|preview|execute) :;; *) exit 2;; esac
days="${PRESSGARDEN_CLEANUP_DAYS:-30}"; logs=0; development=0
for arg in "$@"; do case "$arg" in
  --older-than=*) days=${arg#*=};; --logs) logs=1;; --development) development=1;;
  *) printf 'Unknown cleanup option: %s\n' "$arg" >&2; exit 2;; esac
done
[[ "$days" =~ ^[1-9][0-9]{0,4}$ ]] || exit 2
# Discovery does not bootstrap WordPress. No WP-CLI is needed for file cleanup.
discover_sites
if [ "$action" = execute ]; then
  php "$PRESSGARDEN_DIR/lib/ops-safety.php" scope "$PRESSGARDEN_STATE_DIR" "${WP_SITES[@]}" || exit 2
  pg_confirm "Back up then remove old disposable files on ${#WP_SITES[@]} selected site(s)? Current logs and application code remain untouched." || exit 1
fi
# Excluded children are traversal boundaries, never cleanup targets.
sites_json=$(php -r 'echo json_encode(array_slice($argv,1));' "${WP_SITES[@]}" "${MANUAL_EXCLUDED_ROOTS[@]}") || exit 2
failed=0; review=0; completed=0
for site in "${WP_SITES[@]}"; do
  pg_unlock_site
  if [ "$action" = execute ]; then pg_lock_site "$site" || { failed=$((failed+1)); continue; }; fi
  printf '\n%s\n' "$(site_label_from_root "$site")"; rc=0
  php "$PRESSGARDEN_DIR/lib/cleanup.php" "$action" "$PRESSGARDEN_STATE_DIR" "$site" "$days" "$logs" "$development" v1 "$sites_json" || rc=$?
  case "$rc" in 0) completed=$((completed+1));; 1) review=$((review+1));; *) failed=$((failed+1));; esac
done
pg_unlock_site
printf '\nFleet summary: completed %s; review %s; failed %s\n' "$completed" "$review" "$failed"
[ "$failed" -eq 0 ] || exit 2
[ "$review" -eq 0 ] || exit 1
