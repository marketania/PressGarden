#!/usr/bin/env bash
# Opt-in integration against two fresh fixture sites and uniquely named CI DBs.
# Never accepts an arbitrary site path or database name from the caller.
set -euo pipefail
[ "${PRESS_FAMILY_ALLOW_ISOLATED_WP_TEST:-0}" = 1 ] || { echo 'Live fixture integration requires explicit isolated-test opt-in.' >&2;exit 2; }
[ -n "${PRESS_TEST_DB_PASSWORD:-}" ] || { echo 'Ephemeral local CI MySQL password required.' >&2;exit 2; }
REPO=$(cd "$(dirname "$0")/.." && pwd -P);product=$(cat "$REPO/PRODUCT");program=${product,,};prefix=${product^^}
T=$(mktemp -d); tag="press_family_ci_${program}_$$_${RANDOM}";dbs=();sites=()
cleanup(){
 for i in "${!sites[@]}";do
  case "${sites[$i]}" in "$T"/fleet/*) :;; *) continue;; esac
  current=$(wp --path="${sites[$i]}" config get DB_NAME 2>/dev/null || true)
  [ "$current" != "${dbs[$i]}" ] || wp --path="${sites[$i]}" db drop --yes >/dev/null 2>&1 || true
 done
 rm -rf -- "$T"
}
trap cleanup EXIT
# Fixed loopback service; names and filesystem paths are generated only here.
for label in a b;do
 site="$T/fleet/$label.example/public_html";db="${tag}_${label}";mkdir -p "$site"
 wp core download --path="$site" --quiet
 wp config create --path="$site" --dbname="$db" --dbuser=root --dbpass="$PRESS_TEST_DB_PASSWORD" --dbhost=127.0.0.1:3306 --skip-check --quiet
 wp db create --path="$site" --quiet
 dbs+=("$db");sites+=("$site")
 wp core install --path="$site" --url="http://$label.example.invalid" --title='Isolated Press family fixture' --admin_user=fixture_admin --admin_password='CI-only-not-a-production-secret-7319' --admin_email=fixture@example.invalid --skip-email --quiet
 done
site=${sites[0]};other=${sites[1]};otherhash=$(sha256sum "$other/wp-config.php" | awk '{print $1}')
export "${prefix}_SCAN_ROOT=$T/fleet" "${prefix}_CONFIG_FILE=$T/no-config" "${prefix}_STATE_DIR=$T/state" "${prefix}_CACHE_DIR=$T/cache" "${prefix}_INTERACTIVE=0" "${prefix}_PROGRESS=0" "${prefix}_NOCOLOR=1" "${prefix}_OUTPUT_JSON=0"
run(){ bash "$REPO/$program" "$@"; }
run sites
case "$program" in
 pressharden)
  run lock a.example;[ "$(wp config get DISALLOW_FILE_MODS --path="$site")" = true ]
  [ "$otherhash" = "$(sha256sum "$other/wp-config.php" | awk '{print $1}')" ]
  run unlock a.example;[ "$(wp config get DISALLOW_FILE_MODS --path="$site")" = false ]
  run wp-settings set editor disabled a.example;[ "$(wp config get DISALLOW_FILE_EDIT --path="$site")" = true ]
  run wp-settings set debug-display disabled a.example;[ "$(wp config get WP_DEBUG_DISPLAY --path="$site")" = false ]
  run auto-updates core disabled a.example
  mkdir -p "$site/wp-content/plugins/press-fixture"
  printf '<?php\n/* Plugin Name: Isolated Press Fixture */\n' > "$site/wp-content/plugins/press-fixture/press-fixture.php"
  run auto-updates plugins enable a.example
  wp option get auto_update_plugins --format=json --path="$site" | grep -q press-fixture
  before=$(wp config get AUTH_KEY --path="$site");run salts rotate auth a.example;after=$(wp config get AUTH_KEY --path="$site");[ "$before" != "$after" ];unset before after
  run salts rotate cache a.example > "$T/cache-skip"
  grep -q SKIPPED "$T/cache-skip"
  find "$T/state" -name '*.bak' -o -name '*.json' | grep -q .
  ;;
 pressgarden)
  run db check a.example
  run db repair a.example
  run db optimize a.example
  wp option add _transient_press_fixture harmless --path="$site"
  wp option add _transient_timeout_press_fixture 100 --path="$site"
  run db cleanup a.example
  [ "$(wp option get _transient_press_fixture --path="$site")" = harmless ]
  run db cleanup a.example --execute
  if wp option get _transient_press_fixture --path="$site" >/dev/null 2>&1;then echo 'Expired transient remained' >&2;exit 1;fi
  wp plugin install litespeed-cache --activate --path="$site" --quiet
  run litespeed status a.example
  run cache disable a.example
  [ "$(wp litespeed-option get cache --path="$site" --skip-themes --skip-packages --no-color)" = 0 ]
  run cache enable a.example
  [ "$(wp litespeed-option get cache --path="$site" --skip-themes --skip-packages --no-color)" = 1 ]
  run litespeed-db status a.example
  run litespeed-db optimize a.example
  find "$T/state/backups" -name '*.sql' | grep -q .
  ;;
 *)
  set +e;run inspect db a.example;rc=$?;set -e;[ "$rc" -le 1 ]
  run intel status
  run baseline create a.example
  run changes a.example
  ;;
esac
[ "$otherhash" = "$(sha256sum "$other/wp-config.php" | awk '{print $1}')" ]
# Invalid names never fall back to the unrelated fixture.
set +e;run doctor nonexistent.example >/dev/null 2>&1;rc=$?;set -e;[ "$rc" -eq 2 ]
printf '\n%s live WordPress / MySQL fixture integration PASS\n' "$product"
wp core version --path="$site"
wp --info
