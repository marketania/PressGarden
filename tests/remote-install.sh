#!/usr/bin/env bash
# Exercise the documented downloaded-installer path with an inert local curl
# transport. No production sites, credentials, or network services are used.
set -euo pipefail
umask 077
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
product=$(cat "$REPO/PRODUCT"); program=${product,,}; prefix=${product^^}
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/tmp" "$T/source/$product-main"
cp -R "$REPO/." "$T/source/$product-main/"
rm -rf -- "$T/source/$product-main/.git"
# Directory modes are not tracked by git; normalize fixture packaging only.
find "$T/source" -type d -exec chmod 755 {} +
(unset TAR_OPTIONS GZIP; tar -czf "$T/source.tar.gz" -C "$T/source" "$product-main")
cat > "$T/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=''; out=''; https=0; redirect_https=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --proto) [ "$2" = '=https' ]; https=1; shift 2 ;;
    --proto-redir) [ "$2" = '=https' ]; redirect_https=1; shift 2 ;;
    --connect-timeout|--max-time|--max-filesize) shift 2 ;;
    -fsSL) shift ;;
    https://*) url=$1; shift ;;
    *) echo 'Unexpected fixture download argument' >&2; exit 90 ;;
  esac
done
[ "$url" = "https://github.com/marketania/$TEST_PRODUCT/archive/refs/heads/main.tar.gz" ]
[ -n "$out" ] && [ "$https" = 1 ] && [ "$redirect_https" = 1 ]
[ "${TEST_DOWNLOAD_FAIL:-0}" != 1 ] || exit 22
cp -- "$TEST_ARCHIVE" "$out"
CURL
chmod 755 "$T/bin/curl"
install_remote() {
  local archive=$1 dest=$2 mode=${3:-portable}
  # Intentionally do NOT set INSTALL_SOURCE: this must test the download branch.
  env -i PATH="$T/bin:$PATH" HOME="$T/home" TMPDIR="$T/tmp" \
    TEST_PRODUCT="$product" TEST_ARCHIVE="$archive" \
    TEST_DOWNLOAD_FAIL="${TEST_DOWNLOAD_FAIL:-0}" \
    TAR_OPTIONS='--strip-components=20' GZIP='--invalid-fixture-option' \
    "${prefix}_INSTALL_MODE=$mode" "${prefix}_INSTALL_PREFIX=$dest" \
    "${prefix}_CONFIG_FILE=$T/user-config/config" "${prefix}_BIN_DIR=$T/user-bin" \
    bash -c "$(cat "$REPO/install.sh")"
}
assert_rejected() {
  local archive=$1 dest=$2 message=$3 rc=0
  install_remote "$archive" "$dest" > "$T/reject.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo 'Unsafe remote install unexpectedly succeeded' >&2; exit 1; }
  [ ! -e "$dest" ] && [ ! -L "$dest" ]
  grep -q "$message" "$T/reject.log" || { cat "$T/reject.log"; exit 1; }
}
install_remote "$T/source.tar.gz" "$T/portable" > "$T/portable.log" 2>&1 || { cat "$T/portable.log"; exit 1; }
[ -f "$T/portable/.${program}-portable" ] && [ -x "$T/portable/$program" ]
[ "$(cat "$T/portable/PRODUCT")" = "$product" ]
[ "$(cat "$T/portable/VERSION")" = "$(cat "$REPO/VERSION")" ]
env -i PATH="$PATH" HOME="$T/home" bash "$T/portable/$program" --version | grep -q "$product"
install_remote "$T/source.tar.gz" "$T/user" user > "$T/user.log" 2>&1 || { cat "$T/user.log"; exit 1; }
[ -L "$T/user-bin/$program" ] && [ -f "$T/user-config/config" ]
env -i PATH="$PATH" HOME="$T/home" "$T/user-bin/$program" --version | grep -q "$product"
# Existing installations and unrelated user state must remain untouched.
printf 'retain me\n' > "$T/portable/sentinel"
rc=0; install_remote "$T/source.tar.gz" "$T/portable" > "$T/existing.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] && grep -q 'Destination exists' "$T/existing.log"
grep -q 'retain me' "$T/portable/sentinel"
# Cross-product, invalid archive, unsafe link and failed transport all fail closed.
printf 'OtherProduct\n' > "$T/source/$product-main/PRODUCT"
(unset TAR_OPTIONS GZIP; tar -czf "$T/wrong.tar.gz" -C "$T/source" "$product-main")
assert_rejected "$T/wrong.tar.gz" "$T/wrong" 'identity mismatch'
printf 'not an archive\n' > "$T/bad.tar.gz"
assert_rejected "$T/bad.tar.gz" "$T/bad" 'Update validation failed'
printf '%s\n' "$product" > "$T/source/$product-main/PRODUCT"
ln -s /etc/passwd "$T/source/$product-main/unsafe-link"
(unset TAR_OPTIONS GZIP; tar -czf "$T/link.tar.gz" -C "$T/source" "$product-main")
assert_rejected "$T/link.tar.gz" "$T/linked" 'Update validation failed'
rc=0; TEST_DOWNLOAD_FAIL=1 install_remote "$T/source.tar.gz" "$T/download-failed" > "$T/fetch.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/download-failed" ]
[ -z "$(find "$T/tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]
printf '%s remote installer: portable/user install, HTTPS arguments, tar environment isolation, identity/archive/link/transport refusal and cleanup PASS\n' "$product"
