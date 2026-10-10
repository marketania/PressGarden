#!/usr/bin/env bash
# Independent local development; never load host configuration or credentials.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
program=$(tr '[:upper:]' '[:lower:]' < "$REPO/PRODUCT")
image="$program-dev:local"
mode=${1:-test}
[ "$#" -le 1 ] || { echo 'Usage: bash dev/run.sh setup|build|versions|test|shell|integration' >&2; exit 2; }
case "$mode" in setup|build|versions|test|shell|integration) ;; *) echo 'Unknown development action.' >&2; exit 2;; esac
command -v docker >/dev/null || { echo 'Docker is required; see docs/CLOUD-DEVELOPMENT.md.' >&2; exit 2; }

# Build metadata belongs in a writable temporary directory, including when the
# saved cloud environment has a read-only home. Keep the administrator's existing
# Docker configuration and approved proxy routing; do not copy or change it.
session=$(mktemp -d "${TMPDIR:-/tmp}/$program-dev.XXXXXXXX")
db=''; network=''
docker_cmd() { BUILDX_CONFIG="$session/buildx" command docker "$@"; }
cleanup() {
  [ -z "$db" ] || docker_cmd rm --force "$db" >/dev/null 2>&1 || true
  [ -z "$network" ] || docker_cmd network rm "$network" >/dev/null 2>&1 || true
  rm -rf -- "$session"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$session/buildx"

if [ "$mode" = build ] || [ "$mode" = setup ]; then
  command -v curl >/dev/null || { echo 'curl is required to fetch the official WP-CLI build.' >&2; exit 2; }
  mkdir -p "$session/wp-cli-artifact"
  curl -fsSL --proto '=https' --proto-redir '=https' \
    https://raw.githubusercontent.com/wp-cli/builds/f543a4ebc6c1daa6591799edb0ce4cf7c9e0f2c5/phar/wp-cli.phar \
    -o "$session/wp-cli-artifact/wp-cli.phar"
  printf '%s  %s\n' ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c "$session/wp-cli-artifact/wp-cli.phar" | sha256sum -c -
  # Only dev/ enters the build context; private state and the checkout stay out.
  docker_cmd build --build-context "wp_cli=$session/wp-cli-artifact" \
    --tag "$image" --file "$REPO/dev/Dockerfile" "$REPO/dev"
  exit
fi
docker_cmd image inspect "$image" >/dev/null || { echo 'Run bash dev/run.sh setup or build first.' >&2; exit 2; }
runtime=(--rm --init --user "$(id -u):$(id -g)" --read-only
         --tmpfs /tmp:rw,exec --env HOME=/tmp/press-dev-home
         --env PYTHONDONTWRITEBYTECODE=1 --workdir /work)
# Offline modes do not need even the administrator-provided proxy environment.
if [ "$mode" != integration ]; then
  for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
    runtime+=(--env "$name=")
  done
fi
case "$mode" in
  versions)
    docker_cmd run "${runtime[@]}" --network none "$image" bash -c \
      'mkdir -p "$HOME"; php --version; python3 --version; shellcheck --version; mysql --version; wp --info'
    ;;
  shell)
    terminal=(--interactive); [ ! -t 0 ] || terminal+=(--tty)
    docker_cmd run "${runtime[@]}" "${terminal[@]}" --network none \
      --mount "type=bind,src=$REPO,dst=/work" "$image" bash -c 'mkdir -p "$HOME"; exec bash'
    ;;
  test|integration)
    # Retain only logs on the host. Fixtures, caches and installations stay in
    # the disposable container; the source checkout is mounted read-only.
    logs=$(mktemp -d "${TMPDIR:-/tmp}/$program-dev-logs.XXXXXXXX")
    printf 'Development logs: %s\n' "$logs"
    runtime+=(--mount "type=bind,src=$REPO,dst=/work,readonly"
              --mount "type=bind,src=$logs,dst=/logs"
              --env PRESS_TEST_LOG_DIR=/logs)
    if [ "$mode" = test ]; then
      docker_cmd run "${runtime[@]}" --network none "$image" bash -c '
        set -euo pipefail
        mkdir -p "$HOME"
        mapfile -t files < <(find . -type f -name "*.sh" -not -path "./.git/*" -not -path "./var/*" | sort)
        program=$(tr "[:upper:]" "[:lower:]" < PRODUCT)
        shellcheck --severity=error --shell=bash --format=gcc "$program" "${files[@]}"
        bash tests/run.sh
      '
    else
      # A new private bridge and fresh MySQL container per invocation. There
      # are no host ports, host networking, persistent volumes or site mounts.
      network="$program-dev-$RANDOM-$$"
      db="$network-db"
      docker_cmd network create "$network" >/dev/null
      MYSQL_ROOT_PASSWORD=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
      export MYSQL_ROOT_PASSWORD
      docker_cmd run --detach --name "$db" --network "$network" \
        --tmpfs /var/lib/mysql:rw --env MYSQL_ROOT_PASSWORD \
        --env MYSQL_ROOT_HOST=127.0.0.1 \
        --health-cmd='MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqladmin ping -h 127.0.0.1 --silent' \
        --health-interval=2s --health-timeout=3s --health-retries=60 \
        mysql:8.0@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b >/dev/null
      ready=0
      for ((attempt=0; attempt<90; attempt++)); do
        status=$(docker_cmd inspect --format '{{.State.Health.Status}}' "$db")
        case "$status" in healthy) ready=1; break;; unhealthy) break;; esac
        sleep 2
      done
      [ "$ready" = 1 ] || { echo 'Disposable MySQL did not become healthy.' >&2; exit 2; }
      PRESS_TEST_DB_PASSWORD=$MYSQL_ROOT_PASSWORD
      export PRESS_TEST_DB_PASSWORD
      unset MYSQL_ROOT_PASSWORD
      docker_cmd run "${runtime[@]}" --network "container:$db" \
        --env PRESS_FAMILY_ALLOW_ISOLATED_WP_TEST=1 --env PRESS_TEST_DB_PASSWORD \
        "$image" bash -c 'mkdir -p "$HOME"; bash tests/live-wp.sh' \
        > "$logs/live-wp.log" 2>&1 || { tail -60 "$logs/live-wp.log"; exit 2; }
      unset PRESS_TEST_DB_PASSWORD
      tail -12 "$logs/live-wp.log"
    fi
    ;;
esac
