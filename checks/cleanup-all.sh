#!/usr/bin/env bash
# One cleanup entry point. Read-only previews aggregate independently measured
# categories; mutation uses the existing backup/identity/snapshot guarded paths.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
action="${1:-preview}"; shift || true
case "$action" in preview|status|execute) :;; *) exit 2;; esac
metadata=0; logs=0; development=0; database=0; selected=0; verbose=0; revisions=0
days="${PRESSGARDEN_CLEANUP_DAYS:-30}"; tables=''; blog=''; db_option=0
for arg in "$@"; do
  case "$arg" in
    --files|-files) metadata=1; selected=1;;
    --logs|-logs) logs=1; selected=1;;
    --development|-development) development=1; selected=1;;
    --db|-db) database=1; selected=1;;
    --execute) [ "$action" != status ] || { printf 'status cannot execute cleanup.\n' >&2; exit 2; }; action=execute;;
    --verbose|-v) verbose=1;;
    --older-than=*) days=${arg#*=};;
    --tables=*) tables=${arg#*=}; [[ "$tables" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] || exit 2; db_option=1;;
    --blog=*) blog=${arg#*=}; [[ "$blog" =~ ^[1-9][0-9]*$ ]] || exit 2; db_option=1;;
    --revisions) revisions=1; db_option=1;;
    *) printf 'Unknown cleanup option: %s. See pressgarden help cleanup.\n' "$arg" >&2; exit 2;;
  esac
done
[[ "$days" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$days" -le 36500 ] || { printf 'Cleanup age must be 1–36500 days.\n' >&2; exit 2; }
if [ "$selected" = 0 ]; then metadata=1; logs=1; development=1; database=1; fi
if [ "$db_option" = 1 ] && [ "$database" = 0 ]; then printf 'Database options require -db when category filters are supplied.\n' >&2; exit 2; fi
discover_sites
has_files=$((metadata+logs+development)); categories=()
[ "$metadata" = 0 ] || categories+=('disposable files')
[ "$logs" = 0 ] || categories+=('old rotated logs')
[ "$development" = 0 ] || categories+=('generated development caches')
[ "$database" = 0 ] || categories+=('expired database transients')
[ "$revisions" = 0 ] || categories+=('old revisions (explicit)')
pg_heading "PRESSGARDEN · CLEANUP ${action^^}"
printf '  %s selected site(s) · file/revision age: %s+ days\n' "${#WP_SITES[@]}" "$days"
printf '  Categories: '; _join_array ', ' "${categories[@]}"; printf '\n'
printf '  Current logs, authored settings, code, links and recovery/evidence remain protected.\n'

file_options=("--older-than=$days"); metadata_arg=()
[ "$logs" = 0 ] || file_options+=(--logs)
[ "$development" = 0 ] || file_options+=(--development)
if [ "$metadata" = 0 ]; then file_options+=(--no-metadata); metadata_arg=(no-metadata); fi
db_options=("--older-than=$days")
[ -z "$tables" ] || db_options+=("--tables=$tables")
[ -z "$blog" ] || db_options+=("--blog=$blog")
[ "$revisions" = 0 ] || db_options+=(--revisions)

pg_execute_cleanup() {
  # Check selected provider availability and all native table plans before any
  # category can mutate. The DB runner repeats identity/scope checks at backup
  # and execution; the file runner confirms its actual in-memory candidates.
  if [ "$database" = 1 ] && { [ "$total_expired" -gt 0 ] || [ "$total_revisions" -gt 0 ]; }; then
    command -v wp >/dev/null 2>&1 || { printf '\nINCOMPLETE: database cleanup requires WP-CLI. Use -files/-logs/-development for a file-only request. No cleanup executed.\n' >&2; exit 2; }
    pg_heading 'Database cleanup · private SQL backup and confirmation'
    rc=0; bash "$PRESSGARDEN_DIR/checks/database.sh" cleanup --execute "${db_options[@]}" || rc=$?
    if [ "$rc" -ne 0 ]; then printf '\nINCOMPLETE: database cleanup did not complete; remaining file categories were not executed.\n' >&2; exit "$rc"; fi
  fi
  if [ "$has_files" -gt 0 ] && [ "$total_files" -gt 0 ]; then
    pg_heading 'File cleanup · exact candidate preview, backup and confirmation'
    rc=0; bash "$PRESSGARDEN_DIR/checks/cleanup.sh" execute "${file_options[@]}" || rc=$?
    [ "$rc" -eq 0 ] || { printf '\nCleanup stopped. Review the selected category results above.\n' >&2; exit "$rc"; }
  fi
  printf '\n'; pg_badge COMPLETE; printf ' Selected cleanup categories completed. Recovery paths are listed above.\n'
  exit 0
}

sites_json=$(php -r 'echo json_encode(array_slice($argv,1));' "${WP_SITES[@]}" "${MANUAL_EXCLUDED_ROOTS[@]}") || exit 2
file_report=$(tmpf); db_report=$(tmpf); errors=$(tmpf)
trap 'rm -f -- "$file_report" "$db_report" "$errors"' EXIT
complete=0; ready=0; reviews=0; failed=0; total_files=0; total_bytes=0; total_expired=0; total_revisions=0; total_review=0
display_columns=${COLUMNS:-$W}; compact=0; site_labels=(); site_index=0
[[ "$display_columns" =~ ^[1-9][0-9]{0,4}$ ]] || display_columns=$W
[ "$display_columns" -ge 100 ] || compact=1
for site in "${WP_SITES[@]}"; do
  label=$(pg_display_text "$(site_label_from_root "$site")"); site_labels+=("$label")
  [ "${#label}" -le 30 ] || compact=1
done
printf '\n'
if [ "$compact" = 0 ]; then
  printf '  %-30s %7s %11s %8s %8s %7s  %s\n' SITE FILES 'FILE BYTES' EXPIRED REVISIONS REVIEW STATUS
fi
for site in "${WP_SITES[@]}"; do
  label=${site_labels[$site_index]}; site_index=$((site_index+1)); file_count='-'; file_bytes='-'; file_size='-'; review_count='-'; expired='-'; revision_count='-'; problem=0; warning=0; pending=0; messages=()
  : > "$file_report"
  if [ "$has_files" -gt 0 ]; then
    rc=0
    php "$PRESSGARDEN_DIR/lib/cleanup.php" report "$PRESSGARDEN_STATE_DIR" "$site" "$days" "$logs" "$development" v1 "$sites_json" "${metadata_arg[@]}" > "$file_report" 2> "$errors" || rc=$?
    if [ "$rc" -le 1 ] && [ ! -s "$errors" ] && values=$(php "$PRESSGARDEN_DIR/lib/cleanup-summary.php" files "$file_report" 2>/dev/null); then
      IFS=$'\t' read -r file_count file_bytes review_count <<< "$values"
      file_size=$(human_bytes "$file_bytes"); total_files=$((total_files+file_count)); total_bytes=$((total_bytes+file_bytes)); total_review=$((total_review+review_count))
      [ "$file_count" -eq 0 ] || pending=1
      [ "$review_count" -eq 0 ] || warning=1
    else
      problem=1; file_count='?'; file_size='?'; review_count='?'
      messages+=('File inspection incomplete; no file cleanup was performed.')
      if [ "$verbose" = 1 ] && [ -s "$errors" ]; then messages+=("$(pg_display_text "$(head -c 512 "$errors")")"); fi
    fi
  fi
  if [ "$database" = 1 ]; then
    rc=0
    if ! command -v wp >/dev/null 2>&1; then
      problem=1; expired='?'; [ "$revisions" = 0 ] || revision_count='?'; messages+=('DB unavailable: install WP-CLI or select only file categories.')
    else
      wp eval-file "$PRESSGARDEN_DIR/lib/database.php" cleanup-report "$tables" "$blog" 0 "$revisions" "$days" '' --path="$site" "${WPQ[@]}" > "$db_report" 2> "$errors" || rc=$?
      if [ "$rc" -eq 0 ] && [ ! -s "$errors" ] && values=$(php "$PRESSGARDEN_DIR/lib/cleanup-summary.php" db "$db_report" 2>/dev/null); then
        IFS=$'\t' read -r expired revision_count <<< "$values"
        total_expired=$((total_expired+expired)); total_revisions=$((total_revisions+revision_count))
        [ "$expired" -eq 0 ] && [ "$revision_count" -eq 0 ] || pending=1
        [ "$revisions" = 1 ] || revision_count='-'
      else problem=1; expired='?'; [ "$revisions" = 0 ] || revision_count='?'; messages+=('DB inspection incomplete: check WP-CLI/bootstrap, selected tables and --blog=ID for multisite.'); fi
    fi
  fi
  if [ "$problem" = 1 ]; then status=INCOMPLETE; failed=$((failed+1))
  elif [ "$warning" = 1 ]; then status=REVIEW; reviews=$((reviews+1))
  elif [ "$pending" = 1 ]; then status=READY; ready=$((ready+1))
  else status=CLEAR; complete=$((complete+1)); fi
  if [ "$compact" = 1 ]; then
    printf '  %s\n    ' "$label"; pg_badge "$status"
    printf ' Files %s / %s · Expired %s · Rev %s · Review %s\n' "$file_count" "$file_size" "$expired" "$revision_count" "$review_count"
  else
    printf '  %-30s %7s %11s %8s %8s %7s  ' "$label" "$file_count" "$file_size" "$expired" "$revision_count" "$review_count"; pg_badge "$status"; printf '\n'
  fi
  for message in "${messages[@]}"; do printf '    %s\n' "$message"; done
  if [ "$verbose" = 1 ] && [ "$has_files" -gt 0 ] && [[ "$file_count" =~ ^[0-9]+$ ]]; then
    php "$PRESSGARDEN_DIR/lib/cleanup-summary.php" files-details "$file_report" || exit 2
  fi
done
printf '\n  Fleet: %s clear · %s ready · %s review · %s incomplete\n' "$complete" "$ready" "$reviews" "$failed"
printf '  Observed totals: '
if [ "$has_files" -gt 0 ]; then printf '%s files / %s logical bytes' "$total_files" "$total_bytes"; else printf 'files not selected'; fi
if [ "$database" = 1 ]; then
  printf ' · %s expired transients' "$total_expired"
  if [ "$revisions" = 1 ]; then printf ' · %s revision candidates' "$total_revisions"; else printf ' · revisions not selected'; fi
else printf ' · database not selected'; fi
if [ "$has_files" -gt 0 ]; then printf ' · %s retained review items' "$total_review"; fi
printf '\n  A dash means not selected; ? means inspection incomplete.\n'
printf '  File bytes measure eligible source files, not net disk space reclaimed. Revision counts cap at 1001/site.\n'
if [ "$action" = execute ]; then
  if [ "$failed" -gt 0 ] || [ "$reviews" -gt 0 ]; then
    printf '\nSTOPPED: selected cleanup preflight has incomplete or retained review items. No cleanup executed.\n'
    exit 2
  fi
  php "$PRESSGARDEN_DIR/lib/ops-safety.php" scope "$PRESSGARDEN_STATE_DIR" "${WP_SITES[@]}" || exit 2
  if [ "$ready" -eq 0 ]; then
    printf '\nUNCHANGED: no eligible cleanup items at preflight.\n'
    exit 0
  fi
  pg_execute_cleanup
fi

pg_category_file_count() {
  # Count one file category across the fleet; prints files<TAB>bytes or fails.
  local site rc values n b sum_n=0 sum_b=0
  for site in "${WP_SITES[@]}"; do
    rc=0; : > "$file_report"
    php "$PRESSGARDEN_DIR/lib/cleanup.php" report "$PRESSGARDEN_STATE_DIR" "$site" "$days" "$@" v1 "$sites_json" "${cat_metadata[@]}" > "$file_report" 2> "$errors" || rc=$?
    [ "$rc" -le 1 ] && [ ! -s "$errors" ] || return 1
    values=$(php "$PRESSGARDEN_DIR/lib/cleanup-summary.php" files "$file_report" 2>/dev/null) || return 1
    IFS=$'\t' read -r n b _ <<< "$values"; sum_n=$((sum_n+n)); sum_b=$((sum_b+b))
  done
  printf '%s\t%s\n' "$sum_n" "$sum_b"
}

pg_ask_clean_now() {
  # Terminal-only, default No. A yes runs the category's own guarded execute
  # path, which repeats its exact preview, backup, confirmation and verification.
  local answer=''
  { exec 9<>/dev/tty; } 2>/dev/null || return 1
  printf '\n  %s\n  Clean now? [y/N]: ' "$1" >&9
  IFS= read -r answer <&9 || answer=''
  exec 9>&- 9<&-
  case "$answer" in y|Y|yes|YES) return 0 ;; esac
  printf '  Skipped; %s left unchanged.\n' "$2"
  return 1
}

pg_offer_category_cleanup() {
  [ -t 0 ] && [ "${PRESSGARDEN_INTERACTIVE:-1}" != 0 ] || return 0
  [ "$action" = preview ] && [ "$ready" -gt 0 ] || return 0
  if [ "$failed" -gt 0 ] || [ "$reviews" -gt 0 ]; then
    printf '\n  No cleanup offered: resolve incomplete or retained review items first.\n'
    return 0
  fi
  php "$PRESSGARDEN_DIR/lib/ops-safety.php" scope "$PRESSGARDEN_STATE_DIR" "${WP_SITES[@]}" || return 0
  local rc counts n b label flag cleaned=0
  if [ "$database" = 1 ] && { [ "$total_expired" -gt 0 ] || [ "$total_revisions" -gt 0 ]; } && command -v wp >/dev/null 2>&1; then
    label="Expired database transients: $total_expired"
    [ "$revisions" = 0 ] || label="$label · old revisions: $total_revisions"
    if pg_ask_clean_now "$label (private SQL backup first)." 'database rows'; then
      pg_heading 'Database cleanup · private SQL backup and confirmation'
      rc=0; bash "$PRESSGARDEN_DIR/checks/database.sh" cleanup --execute "${db_options[@]}" || rc=$?
      [ "$rc" -eq 0 ] || { printf '\nINCOMPLETE: database cleanup did not complete; no further categories were offered.\n' >&2; exit "$rc"; }
      cleaned=1
    fi
  fi
  if [ "$has_files" -gt 0 ] && [ "$total_files" -gt 0 ]; then
    for flag in metadata logs development; do
      case "$flag" in
        metadata) [ "$metadata" = 1 ] || continue; label='Disposable files'; cat_metadata=(); counts=$(pg_category_file_count 0 0) || continue; flag_args=();;
        logs) [ "$logs" = 1 ] || continue; label='Old rotated logs'; cat_metadata=(no-metadata); counts=$(pg_category_file_count 1 0) || continue; flag_args=(--logs --no-metadata);;
        development) [ "$development" = 1 ] || continue; label='Generated development caches'; cat_metadata=(no-metadata); counts=$(pg_category_file_count 0 1) || continue; flag_args=(--development --no-metadata);;
      esac
      IFS=$'\t' read -r n b <<< "$counts"
      [ "$n" -gt 0 ] || continue
      if pg_ask_clean_now "$label: $n files / $(human_bytes "$b") (private backup first)." "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"; then
        pg_heading "$label · exact candidate preview, backup and confirmation"
        rc=0; bash "$PRESSGARDEN_DIR/checks/cleanup.sh" execute "--older-than=$days" "${flag_args[@]}" || rc=$?
        [ "$rc" -eq 0 ] || { printf '\nCleanup stopped. Review the category results above.\n' >&2; exit "$rc"; }
        cleaned=1
      fi
    done
  fi
  if [ "$cleaned" = 1 ]; then
    printf '\n'; pg_badge COMPLETE; printf ' Approved cleanup categories completed. Recovery paths are listed above.\n'
    exit 0
  fi
}
cat_metadata=(); flag_args=()
pg_offer_category_cleanup

printf '\n%s%sPREVIEW:%s no website files or database rows changed.\n' "$B" "$C" "$X"
if [ "$failed" -gt 0 ]; then printf 'Resolve incomplete categories before execution; totals cover only verified previews.\n'
elif [ "$reviews" -gt 0 ]; then printf 'Review preserved items with --verbose before executing file cleanup.\n'
elif [ "$ready" -gt 0 ]; then printf 'Next: repeat this cleanup command with --execute; keep the same target and filters.\n'
else printf 'No eligible items in the selected categories. Use --verbose for available details.\n'; fi
[ "$failed" -eq 0 ] || exit 2
[ "$reviews" -eq 0 ] || exit 1
