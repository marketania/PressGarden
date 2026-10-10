#!/usr/bin/env bash
# Local benign-fixture checks only; never launch live WordPress/provider jobs.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$REPO"
for executable in bash php python3 shellcheck git timeout; do
  command -v "$executable" >/dev/null || { printf 'Missing development dependency: %s\n' "$executable" >&2; exit 2; }
done
php -r 'exit(PHP_VERSION_ID >= 70400 && function_exists("gzopen") ? 0 : 2);' || {
  echo 'PHP CLI 7.4+ with zlib is required; use a supported PHP release for deployment.' >&2; exit 2;
}
program=$(tr '[:upper:]' '[:lower:]' < PRODUCT)
list=$(mktemp); trap 'rm -f -- "$list"' EXIT
git ls-files -z -- '*.sh' > "$list"
mapfile -d '' -t files < "$list"
bash -n "$program"
for file in "${files[@]}"; do bash -n "$file"; done
for file in lib/*.php; do php -l "$file" >/dev/null; done
shellcheck --severity=error --shell=bash --format=gcc "$program" "${files[@]}"
bash tests/run.sh
