#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
[ "$#" -eq 0 ] || exit 2
require_wp; discover_sites
failed=0
for site in "${WP_SITES[@]}"; do
  printf '\n%s — maintenance inventory (read-only)\n' "$(site_label_from_root "$site")"
  if ! wp core is-installed --path="$site" "${WPQ[@]}" >/dev/null 2>&1; then printf 'INCOMPLETE: WordPress bootstrap failed.\n'; failed=$((failed+1)); continue; fi
  printf 'Themes (active/inactive inventory, not security findings):\n'
  wp theme list --fields=name,status,version --path="$site" "${WPQ[@]}" || failed=$((failed+1))
  if [ -f "$site/wp-content/object-cache.php" ] && [ ! -L "$site/wp-content/object-cache.php" ]; then
    printf 'Object cache: drop-in present; provider connection/effectiveness not tested.\n'
  else printf 'Object cache: no regular drop-in observed.\n'; fi
done
bash "$PRESSGARDEN_DIR/checks/litespeed-db.sh" status || failed=$((failed+1))
printf '\nUse db check for native table health and cleanup preview for disposable files.\n'
[ "$failed" -eq 0 ] || exit 2
