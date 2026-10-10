#!/usr/bin/env bash
# Verify container isolation and cleanup with a fake Docker CLI, never a service.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s ' "$@" >> "$DOCKER_TEST_TRACE"; printf '\n' >> "$DOCKER_TEST_TRACE"
case "${1:-}" in
  inspect) echo healthy;;
  run)
    case " $* " in *' --detach '*) echo mock-fixture-container;; *) exit "${DOCKER_TEST_RUN_EXIT:-0}";; esac
    ;;
esac
MOCK
chmod +x "$T/bin/docker"
cat > "$T/bin/curl" <<'MOCK'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'Inert corrupt download fixture.\n' > "$2"; exit 0; fi
  shift
done
exit 2
MOCK
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" DOCKER_TEST_TRACE="$T/trace"
run() { : > "$DOCKER_TEST_TRACE"; bash "$REPO/dev/run.sh" "$@" > "$T/output" 2>&1; }
for mode in test versions shell; do
  run "$mode"
  grep -q -- '--network none' "$DOCKER_TEST_TRACE"
  grep -q -- '--read-only' "$DOCKER_TEST_TRACE"
  grep -q -- '--user' "$DOCKER_TEST_TRACE"
  grep -q -- 'HTTP_PROXY=' "$DOCKER_TEST_TRACE"
done
run test
grep -q -- 'dst=/work,readonly' "$DOCKER_TEST_TRACE"
grep -q -- 'bash tests/run.sh' "$DOCKER_TEST_TRACE" || grep -q -- 'tests/run.sh' "$DOCKER_TEST_TRACE"
rc=0; run setup || rc=$?
[ "$rc" != 0 ]; [ ! -s "$DOCKER_TEST_TRACE" ]
grep -q 'FAILED' "$T/output"
run integration
grep -q -- '--network container:' "$DOCKER_TEST_TRACE"
grep -q -- 'dst=/work,readonly' "$DOCKER_TEST_TRACE"
grep -q -- '--tmpfs /var/lib/mysql:rw' "$DOCKER_TEST_TRACE"
grep -q -- 'rm --force' "$DOCKER_TEST_TRACE"
grep -q -- 'network rm' "$DOCKER_TEST_TRACE"
if grep -Eq -- '--network host|--privileged|--publish|/var/run/docker.sock|MYSQL_ROOT_PASSWORD=' "$DOCKER_TEST_TRACE"; then
  echo 'Unsafe host access or inline password in Docker arguments.' >&2; exit 1
fi
export DOCKER_TEST_RUN_EXIT=17
rc=0; run test || rc=$?
[ "$rc" = 17 ]
rc=0; run integration || rc=$?
[ "$rc" = 2 ]
grep -q -- 'rm --force' "$DOCKER_TEST_TRACE"
grep -q -- 'network rm' "$DOCKER_TEST_TRACE"
unset DOCKER_TEST_RUN_EXIT
rc=0; run integration /production/site || rc=$?
[ "$rc" = 2 ]; [ ! -s "$DOCKER_TEST_TRACE" ]
rc=0; run invalid || rc=$?
[ "$rc" = 2 ]; [ ! -s "$DOCKER_TEST_TRACE" ]
printf 'Cloud development: offline/source isolation, bounded arguments, failure propagation and disposable-service cleanup PASS\n'
