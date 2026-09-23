#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
. "$PRESSGARDEN_DIR/lib/database-backup.sh"
action="${1:-status}"; shift || true
case "$action" in status|check|repair|optimize|cleanup) :;; *) exit 2;; esac
tables=''; blog=''; execute=0; revisions=0; days=30
for arg in "$@"; do
  case "$arg" in
    --tables=*) tables=${arg#*=}; [[ "$tables" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || exit 2;;
    --blog=*) blog=${arg#*=}; [[ "$blog" =~ ^[1-9][0-9]*$ ]] || exit 2;;
    --older-than=*) days=${arg#*=}; [[ "$days" =~ ^[1-9][0-9]{0,4}$ ]] || exit 2;;
    --revisions) [ "$action" = cleanup ] || exit 2; revisions=1;;
    --execute) [ "$action" = cleanup ] || exit 2; execute=1;;
    *) printf 'Unknown database option: %s\n' "$arg" >&2; exit 2;;
  esac
done
case "$action" in repair|optimize) execute=1;; esac
require_wp; discover_sites
[ "$execute" = 0 ] || pg_mutation_preflight || exit 2
plans=(); failed=0
for site in "${WP_SITES[@]}"; do
  plan=$(wp eval-file "$PRESSGARDEN_DIR/lib/database.php" plan "$tables" "$blog" 0 "$revisions" "$days" '' --path="$site" "${WPQ[@]}") || { failed=1; continue; }
  [[ "$plan" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || { printf 'Invalid table plan; nothing changed.\n' >&2; failed=1; continue; }
  plans+=("$plan")
  printf 'PREFLIGHT %s: %s\n' "$(site_label_from_root "$site")" "$plan"
done
[ "$failed" = 0 ] && [ "${#plans[@]}" = "${#WP_SITES[@]}" ] || exit 2
if [ "$execute" = 1 ]; then
  pg_confirm "Run database $action on ${#WP_SITES[@]} selected site(s), after private SQL backups?" || exit 1
fi
failed=0; partial=0; completed=0; i=0
for site in "${WP_SITES[@]}"; do
  pg_unlock_site
  if [ "$execute" = 1 ]; then pg_lock_site "$site" || { failed=$((failed+1)); i=$((i+1)); continue; }; fi
  plan=${plans[$i]}; i=$((i+1)); printf '\n%s\n' "$(site_label_from_root "$site")"
  if [ "$execute" = 1 ]; then backup_plan="$plan"; [ "$revisions" = 0 ] || backup_plan=''; pg_database_backup "$site" "$backup_plan" || { failed=$((failed+1)); continue; }; fi
  digest=$(printf '%s' "$plan" | sha256sum | awk '{print $1}')
  rc=0
  wp eval-file "$PRESSGARDEN_DIR/lib/database.php" "$action" "$plan" "$blog" "$execute" "$revisions" "$days" "$digest" --path="$site" "${WPQ[@]}" || rc=$?
  case "$rc" in 0) completed=$((completed+1));; 1) partial=$((partial+1));; *) failed=$((failed+1));; esac
done
pg_unlock_site
printf '\nFleet summary: completed %s; partial %s; failed %s\n' "$completed" "$partial" "$failed"
[ "$failed" -eq 0 ] || exit 2
[ "$partial" -eq 0 ] || exit 1
