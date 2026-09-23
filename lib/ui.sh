count_sites() { printf '%s' "${#SCAN_ROOTS[@]}"; }
count_domains() { printf '%s' "${#DISCOVERED_DOMAINS[@]}"; }
count_ignored_domains() { printf '%s' "${#IGNORED_DOMAINS[@]}"; }

_join_array() {
  local sep="$1"; shift; local first=1 x
  for x in "$@"; do [ "$first" -eq 1 ] || printf '%s' "$sep"; printf '%s' "$x"; first=0; done
}

ignored_domains_summary() { local n=${#IGNORED_DOMAINS[@]}; [ "$n" -gt 0 ] || return 0; printf '%s ignored target(s): ' "$n"; _join_array ', ' "${IGNORED_DOMAINS[@]}"; }
manual_exclusions_summary() { local n=${#MANUAL_EXCLUDED_DOMAINS[@]}; [ "$n" -gt 0 ] || return 0; printf '%s manually excluded site target(s): ' "$n"; _join_array ', ' "${MANUAL_EXCLUDED_DOMAINS[@]}"; }
nested_sites_summary() { local n=${#NESTED_SITES[@]}; [ "$n" -gt 0 ] || return 0; printf '%s nested WordPress install(s): ' "$n"; _join_array ', ' "${NESTED_SITES[@]}"; }

_site_root_for_path() {
  local line="$1" s best='' bestlen=0 l
  for s in "${SCAN_ROOTS[@]}"; do case "$line" in "$s"|"$s"/*) l=${#s}; if [ "$l" -gt "$bestlen" ]; then best="$s"; bestlen=$l; fi ;; esac; done
  [ -n "$best" ] && printf '%s\n' "$best"
}

compact_line() {
  local line="$1" root label rel rest domain
  root=$(_site_root_for_path "$line" 2>/dev/null || true)
  if [ -n "$root" ]; then
    label=$(site_label_from_root "$root"); if [ "$line" = "$root" ]; then rel='WordPress root'; else rel=${line#"$root"/}; fi
    printf '%s%s%s  %s›%s  %s' "$B$M" "$label" "$X" "$D" "$X" "$rel"; return 0
  fi
  case "$line" in "$ROOT"/*/public_html/*) rest=${line#"$ROOT"/}; domain=${rest%%/*}; rest=${rest#*/public_html/}; printf '%s%s%s  %s›%s  %s' "$B$M" "$domain" "$X" "$D" "$X" "$rest" ;; *) printf '%s' "$line" ;; esac
}

_meta_field() {
  local lw="$1" label="$2" text="$3" width t line first=1
  [ -n "$text" ] || return 0; width=$((W - lw - 5)); [ "$width" -lt 36 ] && width=36; t=$(tmpf); printf '%s\n' "$text" | fold -s -w "$width" > "$t"
  while IFS= read -r line; do if [ "$first" -eq 1 ]; then printf '  %s%-*s%s %s\n' "$D" "$lw" "$label" "$X" "$line"; first=0; else printf '  %s%-*s%s %s\n' "$D" "$lw" "" "$X" "$line"; fi; done < "$t"; rm -f "$t"
}

banner() {
  [ -d "$ROOT" ] || die "scan root not found: $ROOT"
  printf '\n%s%s' "$B" "$C"; _repeat '═' "$W"; printf '%s\n' "$X"
  printf '%s%s  PRESSGARDEN OPERATIONS%s  %sv%s%s\n' "$B" "$C" "$X" "$D" "$PRESSGARDEN_VERSION" "$X"
  printf '  %s%-11s%s %s%s%s\n' "$D" "CHECK" "$X" "$B" "$NAME" "$X"
  if [ -n "${PG_SUITE_TOTAL:-}" ]; then _meta_field 11 "PROGRESS" "${PG_SUITE_PERCENT:-0}% suite complete • step ${PG_SUITE_CURRENT:-?}/${PG_SUITE_TOTAL}"; fi
  [ -z "${PG_REPORT_ID:-}" ] || _meta_field 11 "RUN" "$PG_REPORT_ID"
  _meta_field 11 "PURPOSE" "$DESC"; _meta_field 11 "CHECKS" "$SCAN_DOES"; _meta_field 11 "WHY" "$SCAN_WHY"
  printf '  %s%-11s%s %s\n' "$D" "ROOT" "$X" "$ROOT"
  [ "$PRESSGARDEN_CONFIG_LOADED" -eq 1 ] && printf '  %s%-11s%s %s\n' "$D" "CONFIG" "$X" "$PRESSGARDEN_CONFIG_FILE"
  printf '  %s%-11s%s %s%s%s WordPress install(s) across %s site group(s)\n' "$D" "SITES" "$X" "$B" "$(count_sites)" "$X" "$(count_domains)"
  [ "${PG_DISCOVERY_FAILED:-0}" -eq 0 ] || _meta_field 11 "COVERAGE" "INCOMPLETE discovery: validated sites are shown, but one or more paths could not be fully inspected."
  [ "${#NESTED_SITES[@]}" -gt 0 ] && _meta_field 11 "NESTED" "$(nested_sites_summary)"
  [ "${#MANUAL_EXCLUDED_DOMAINS[@]}" -gt 0 ] && _meta_field 11 "EXCLUDED" "$(manual_exclusions_summary)"
  printf '  %s%-11s%s %s\n' "$D" "STARTED" "$X" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s%s' "$B" "$C"; _repeat '═' "$W"; printf '%s\n' "$X"
}

sec() { SECN=$((SECN+1)); SEC_T0=$(date +%s); CURRENT_SECTION="$1"; printf '\n%s%s◆ %02d%s  %s%s%s' "$B" "$C" "$SECN" "$X" "$B" "$1" "$X"; [ $# -gt 1 ] && printf '  %s(%s)%s' "$D" "$2" "$X"; printf '\n'; }
note() { printf '    %sℹ%s  %s\n' "$C" "$X" "$1"; }
_save_details() { local f="$1" sev="$2"; [ -n "${DETAIL_LOG:-}" ] || return 0; { printf '\n[%02d] %s | severity=%s | matches=%s\n' "$SECN" "$CURRENT_SECTION" "$sev" "$(grep -c . "$f" 2>/dev/null || true)" && cat "$f"; } >> "$DETAIL_LOG"; }
