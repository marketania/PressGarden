#!/usr/bin/env bash
# All local tests use benign temporary fixtures. External integration is separate.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P); cd "$REPO" || exit 2
LOGS="${PRESS_TEST_LOG_DIR:-$(mktemp -d)}"; mkdir -p "$LOGS" || exit 2
failed=0; passed=0
: > "$LOGS/results.tsv"
for file in "$REPO"/*.sh "$REPO"/checks/*.sh "$REPO"/lib/*.sh "$REPO"/suites/*.sh; do
  [ -f "$file" ] || continue
  bash -n "$file" || failed=$((failed+1))
done
program=$(tr '[:upper:]' '[:lower:]' < PRODUCT); bash -n "$program" || failed=$((failed+1))
for file in lib/*.php; do php -l "$file" >/dev/null || failed=$((failed+1)); done
for file in tests/*; do
  case "${file##*/}" in run.sh|live-wp.sh|upstream-corpus.sh|php-upstream.sh|db-mysql.php) continue;; esac
  case "$file" in *.sh) interpreter=bash;; *.php) interpreter=php;; *.py) interpreter=python3;; *) continue;; esac
  rc=0; timeout --kill-after=5s 240s "$interpreter" "$file" > "$LOGS/${file##*/}.log" 2>&1 || rc=$?
  printf '%s\t%s\n' "$file" "$rc" >> "$LOGS/results.tsv"
  if [ "$rc" -eq 0 ]; then passed=$((passed+1)); printf 'PASS %s\n' "$file"
  else failed=$((failed+1)); printf 'FAIL %s (exit %s)\n' "$file" "$rc"; tail -60 "$LOGS/${file##*/}.log"; fi
done
printf '\nLocal validation: %s passed tests; %s failures including syntax. Logs: %s\n' "$passed" "$failed" "$LOGS"
[ "$failed" -eq 0 ]
