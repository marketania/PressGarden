#!/usr/bin/env bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
product=$(cat "$REPO/PRODUCT"); program=${product,,}; prefix=${product^^}
mkdir -p "$T/home" "$T/candidate"
cp -R "$REPO/." "$T/candidate/"
# Git metadata is not part of a release archive.
rm -rf "$T/candidate/.git"
# Do not let arbitrary home config, shell state, or remote services enter a test.
export HOME="$T/home"
export "${prefix}_CONFIG_FILE=$T/no-config" "${prefix}_INTERACTIVE=0"
DEST="$T/installed"
env "${prefix}_INSTALL_SOURCE=$REPO" "${prefix}_INSTALL_PREFIX=$DEST" bash "$REPO/install.sh" > "$T/install.log"
[ -f "$DEST/.${program}-portable" ]; [ -x "$DEST/$program" ]
bash "$DEST/$program" --version | grep -q "$product"
printf '\n# keep-this-config\n' >> "$DEST/config/config"
mkdir -p "$DEST/var/backups"; echo retained > "$DEST/var/backups/sentinel"
printf '0.1.1\n' > "$T/candidate/VERSION"
tar -czf "$T/update.tar.gz" -C "$T" candidate
env "${prefix}_UPDATE_ARCHIVE=$T/update.tar.gz" bash "$DEST/$program" update > "$T/update.log" 2>&1 || { cat "$T/update.log"; exit 1; }
[ "$(cat "$DEST/VERSION")" = 0.1.1 ]; grep -q keep-this-config "$DEST/config/config"; grep -q retained "$DEST/var/backups/sentinel"
# Cross-product archive identity must fail before code replacement.
printf 'OtherProduct\n' > "$T/candidate/PRODUCT"
tar -czf "$T/wrong.tar.gz" -C "$T" candidate
set +e
env "${prefix}_UPDATE_ARCHIVE=$T/wrong.tar.gz" bash "$DEST/$program" update > "$T/wrong.log" 2>&1
rc=$?; set -e
[ "$rc" -ge 2 ]; [ "$(cat "$DEST/PRODUCT")" = "$product" ]; [ "$(cat "$DEST/VERSION")" = 0.1.1 ]
grep -q 'identity mismatch' "$T/wrong.log"
# Existing destinations are not silently replaced by the installer.
if env "${prefix}_INSTALL_SOURCE=$REPO" "${prefix}_INSTALL_PREFIX=$DEST" bash "$REPO/install.sh" >/dev/null 2>&1; then exit 1; fi
# Independent symlink/user-wide install and default-config isolation.
env "${prefix}_CONFIG_FILE=$T/user-config/config" "${prefix}_INSTALL_SOURCE=$REPO" "${prefix}_INSTALL_MODE=user" "${prefix}_INSTALL_PREFIX=$T/user-install" "${prefix}_BIN_DIR=$T/bin" bash "$REPO/install.sh" > "$T/user.log"
[ -L "$T/bin/$program" ]; "$T/bin/$program" --version | grep -q "$product"
env "${prefix}_BIN_DIR=$T/bin" bash "$T/user-install/uninstall.sh" --yes > /dev/null
[ ! -e "$T/bin/$program" ]; [ -f "$T/user-config/config" ]
bash "$DEST/uninstall.sh" --yes > /dev/null
[ ! -e "$DEST/$program" ]; grep -q keep-this-config "$DEST/config/config"; grep -q retained "$DEST/var/backups/sentinel"
printf '%s lifecycle: standalone portable/user install, real program update, identity refusal, config/state preservation, uninstall PASS\n' "$product"
