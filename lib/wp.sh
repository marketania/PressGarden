# ---------- WP-CLI helpers ----------
WP_SITES=()
require_wp() {
  command -v wp >/dev/null 2>&1 || die "wp-cli not found in PATH"
  [ -d "$ROOT" ] || die "scan root not found: $ROOT"
}

discover_sites() {
  refresh_scan_roots
  [ "${PG_DISCOVERY_FAILED:-0}" -eq 0 ] || die "incomplete discovery; operation refused"
  WP_SITES=("${SCAN_ROOTS[@]}")
  [ "${#WP_SITES[@]}" -gt 0 ] || die "no non-excluded WordPress installs found under $ROOT"
}

site_domain() { site_label_from_root "$1"; }
WPQ=(--skip-plugins --skip-themes --skip-packages --no-color)
wpq() { local p="$1"; shift; wp "$@" --path="$p" "${WPQ[@]}" 2>&1; }

ok() {
  printf '    %s%s✓ OK%s     %s%s%s  %s\n' "$B" "$G" "$X" "$B" "$1" "$X" "${2:-}"
}
issue() {
  TOTAL=$((TOTAL+1)); ALERTS=$((ALERTS+1))
  printf '    %s%s✖ FAILED%s  %s%s%s  %s\n' "$B" "$R" "$X" "$B" "$1" "$X" "${2:-}"
  [ $# -gt 2 ] && printf '%s\n' "$3" | sed 's/^/        /'
}
flag() {
  TOTAL=$((TOTAL+1)); REVIEWS=$((REVIEWS+1))
  printf '    %s%s⚠ REVIEW%s %s%s%s  %s\n' "$B" "$Y" "$X" "$B" "$1" "$X" "${2:-}"
  [ $# -gt 2 ] && printf '%s\n' "$3" | sed 's/^/        /'
}
