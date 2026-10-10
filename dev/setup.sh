#!/usr/bin/env bash
# Install tools only inside the disposable official Debian development image.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run through bash dev/run.sh setup or the development Dockerfile.' >&2; exit 2; }
[ -f /etc/os-release ] || exit 2
. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_CODENAME" = trixie ] || { echo 'This setup requires the documented Debian trixie image.' >&2; exit 2; }
apt-get update --error-on=any
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  bash ca-certificates coreutils curl diffutils file findutils gawk git \
  grep gzip jq mariadb-client openssl php-cli php-curl php-mbstring \
  php-mysql php-xml php-zip procps python3 sed shellcheck tar unzip \
  util-linux wget yara
rm -rf /var/lib/apt/lists/*
php -r 'exit(function_exists("gzopen") && extension_loaded("mysqli") ? 0 : 2);'
dpkg-query -W -f='${Package}\t${Version}\n' > /usr/local/share/press-dev-packages.tsv
