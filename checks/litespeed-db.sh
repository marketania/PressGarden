#!/usr/bin/env bash
# litespeed-db — verified LiteSpeed Cache database cleanup/optimization.
#
# State is measured with LiteSpeed's own DB_Optm::db_count() counters, which are
# the same counters shown in LiteSpeed Cache > Database > Manage. Real database
# actions run from the WordPress directory without ordinary WP-CLI global flags.
set -uo pipefail
NAME=litespeed-db
DESC="verified LiteSpeed Cache database cleanup and optimization"
SCAN_DOES="Reads the same LiteSpeed database counters shown in wp-admin, runs documented cleanup command groups, then re-reads those counters before reporting a verified result."
SCAN_WHY="A successful CLI exit code proves only that a command returned successfully. PressGarden verifies the database state itself so cleanup is never labeled successful when LiteSpeed still reports pending optimization work."
. "$(cd "$(dirname "$0")/.." && pwd)/lib/_lib.sh"
. "$PRESSGARDEN_DIR/lib/database-backup.sh"

ACTION="${1:-status}"
case "$ACTION" in
  status|optimize) : ;;
  *) printf 'Use litespeed-db status or litespeed-db optimize.\n' >&2; exit 2 ;;
esac

_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Built-in WordPress inventory commands can skip plugins. The state probe below
# deliberately does NOT skip plugins because it calls LiteSpeed's own DB_Optm.
_wp_builtin() {
  local site="$1"; shift
  wp "$@" --path="$site" --skip-plugins --skip-themes --skip-packages --no-color
}
_wp_bootstrap_ok() { _wp_builtin "$1" core is-installed >/dev/null 2>&1; }
_lscwp_installed() { _wp_builtin "$1" plugin is-installed litespeed-cache >/dev/null 2>&1; }
_lscwp_active() { _wp_builtin "$1" plugin is-active litespeed-cache >/dev/null 2>&1; }
_is_multisite() { _wp_builtin "$1" core is-installed --network >/dev/null 2>&1; }

_lscwp_commands_available() {
  local site="$1"
  # One family-level probe is enough. The previous implementation requested
  # help for five subcommands per site, causing hundreds of redundant WordPress
  # bootstraps before a fleet run could begin changing the first database.
  (cd "$site" 2>/dev/null && PAGER=cat WP_CLI_PAGER=cat wp help litespeed-database >/dev/null 2>&1)
}

_multisite_blog_ids() {
  local site="$1" raw id clean seen='' count=0
  raw=$(_wp_builtin "$site" site list --field=blog_id 2>/dev/null) || return 1
  while IFS= read -r id; do
    clean="$id"
    clean="${clean#"${clean%%[![:space:]]*}"}"
    clean="${clean%"${clean##*[![:space:]]}"}"
    [ -n "$clean" ] || continue
    case "$clean" in *[!0-9]*) return 1 ;; esac
    [ "$clean" -gt 0 ] 2>/dev/null || return 1
    case " $seen " in *" $clean "*) continue ;; esac
    printf '%s\n' "$clean"
    seen="$seen $clean"
    count=$((count+1))
  done <<< "$raw"
  [ "$count" -gt 0 ]
}

_format_bytes() {
  awk -v n="${1:-0}" 'BEGIN {
    split("B KB MB GB TB", u, " "); i=1;
    while (n >= 1024 && i < 5) { n/=1024; i++ }
    if (i == 1) printf "%.0f %s", n, u[i];
    else if (n >= 100) printf "%.0f %s", n, u[i];
    else if (n >= 10) printf "%.1f %s", n, u[i];
    else printf "%.2f %s", n, u[i];
  }'
}

# Current measured LiteSpeed state. Counters are summed across validated blogs
# for multisite; database size is installation-wide and recorded once.
LS_REV=0; LS_ORPH=0; LS_AUTO=0; LS_TRASH_POST=0; LS_SPAM=0
LS_TRASH_COMMENT=0; LS_TRACK=0; LS_EXPIRED=0; LS_TRANSIENTS=0
LS_TABLES=0; LS_SIZE=''; LS_BLOGS=1

_capture_blog_state() {
  local site="$1" blog="${2:-}" out rc row magic status effective rev orph auto trash spam trashc track exp trans tables size extra
  out=$(tmpf)
  PRESSGARDEN_LSDB_BLOG="$blog" wp eval-file "$PRESSGARDEN_DIR/lib/litespeed-db-state.php" \
    --path="$site" --skip-themes --skip-packages --no-color >"$out" 2>&1
  rc=$?
  row=$(awk -F '\t' '$1=="PWLSDB1" && $2=="OK" {line=$0} END{print line}' "$out")
  rm -f "$out"
  [ "$rc" -eq 0 ] && [ -n "$row" ] || return 1
  IFS=$'\t' read -r magic status effective rev orph auto trash spam trashc track exp trans tables size extra <<< "$row"
  [ "$magic" = PWLSDB1 ] && [ "$status" = OK ] && [ -z "${extra:-}" ] || return 1
  for n in "$effective" "$rev" "$orph" "$auto" "$trash" "$spam" "$trashc" "$track" "$exp" "$trans" "$tables"; do
    _is_uint "$n" || return 1
  done
  if [ "$size" != '-' ]; then _is_uint "$size" || return 1; fi
  LS_ONE_REV=$rev; LS_ONE_ORPH=$orph; LS_ONE_AUTO=$auto; LS_ONE_TRASH_POST=$trash
  LS_ONE_SPAM=$spam; LS_ONE_TRASH_COMMENT=$trashc; LS_ONE_TRACK=$track
  LS_ONE_EXPIRED=$exp; LS_ONE_TRANSIENTS=$trans; LS_ONE_TABLES=$tables; LS_ONE_SIZE=$size
}

_capture_install_state() {
  local site="$1" multisite="$2" ids blog count=0 first_size=''
  LS_REV=0; LS_ORPH=0; LS_AUTO=0; LS_TRASH_POST=0; LS_SPAM=0
  LS_TRASH_COMMENT=0; LS_TRACK=0; LS_EXPIRED=0; LS_TRANSIENTS=0
  LS_TABLES=0; LS_SIZE=''; LS_BLOGS=1
  if [ "$multisite" = 1 ]; then
    ids=$(_multisite_blog_ids "$site") || return 1
  else
    ids=''
  fi
  if [ "$multisite" = 1 ]; then
    while IFS= read -r blog; do
      [ -n "$blog" ] || continue
      _capture_blog_state "$site" "$blog" || return 1
      LS_REV=$((LS_REV+LS_ONE_REV)); LS_ORPH=$((LS_ORPH+LS_ONE_ORPH)); LS_AUTO=$((LS_AUTO+LS_ONE_AUTO)); LS_TRASH_POST=$((LS_TRASH_POST+LS_ONE_TRASH_POST))
      LS_SPAM=$((LS_SPAM+LS_ONE_SPAM)); LS_TRASH_COMMENT=$((LS_TRASH_COMMENT+LS_ONE_TRASH_COMMENT)); LS_TRACK=$((LS_TRACK+LS_ONE_TRACK))
      LS_EXPIRED=$((LS_EXPIRED+LS_ONE_EXPIRED)); LS_TRANSIENTS=$((LS_TRANSIENTS+LS_ONE_TRANSIENTS)); LS_TABLES=$((LS_TABLES+LS_ONE_TABLES))
      [ -n "$first_size" ] || first_size=$LS_ONE_SIZE
      count=$((count+1))
    done <<< "$ids"
    [ "$count" -gt 0 ] || return 1
    LS_BLOGS=$count
    LS_SIZE=$first_size
  else
    _capture_blog_state "$site" '' || return 1
    LS_REV=$LS_ONE_REV; LS_ORPH=$LS_ONE_ORPH; LS_AUTO=$LS_ONE_AUTO; LS_TRASH_POST=$LS_ONE_TRASH_POST
    LS_SPAM=$LS_ONE_SPAM; LS_TRASH_COMMENT=$LS_ONE_TRASH_COMMENT; LS_TRACK=$LS_ONE_TRACK
    LS_EXPIRED=$LS_ONE_EXPIRED; LS_TRANSIENTS=$LS_ONE_TRANSIENTS; LS_TABLES=$LS_ONE_TABLES
    LS_SIZE=$LS_ONE_SIZE; LS_BLOGS=1
  fi
}

_state_pending() {
  [ "$LS_REV" -gt 0 ] || [ "$LS_ORPH" -gt 0 ] || [ "$LS_AUTO" -gt 0 ] || [ "$LS_TRASH_POST" -gt 0 ] ||
  [ "$LS_SPAM" -gt 0 ] || [ "$LS_TRASH_COMMENT" -gt 0 ] || [ "$LS_TRACK" -gt 0 ] || [ "$LS_EXPIRED" -gt 0 ] ||
  [ "$LS_TRANSIENTS" -gt 0 ] || [ "$LS_TABLES" -gt 0 ]
}

_print_state() {
  local heading="$1"
  printf '    %s\n' "$heading"
  printf '      %-24s %10s\n' 'Post revisions:' "$LS_REV"
  printf '      %-24s %10s\n' 'Orphaned post meta:' "$LS_ORPH"
  printf '      %-24s %10s\n' 'Auto drafts:' "$LS_AUTO"
  printf '      %-24s %10s\n' 'Trashed posts:' "$LS_TRASH_POST"
  printf '      %-24s %10s\n' 'Spam comments:' "$LS_SPAM"
  printf '      %-24s %10s\n' 'Trashed comments:' "$LS_TRASH_COMMENT"
  printf '      %-24s %10s\n' 'Trackbacks/Pingbacks:' "$LS_TRACK"
  printf '      %-24s %10s\n' 'Expired transients:' "$LS_EXPIRED"
  printf '      %-24s %10s\n' 'All transient rows:' "$LS_TRANSIENTS"
  printf '      %-24s %10s\n' 'Tables to optimize:' "$LS_TABLES"
  if _is_uint "$LS_SIZE"; then printf '      %-24s %10s\n' 'DB allocation estimate:' "$(_format_bytes "$LS_SIZE")"; else printf '      %-24s %10s\n' 'DB allocation estimate:' 'unavailable'; fi
  [ "$LS_BLOGS" -le 1 ] || printf '      %-24s %10s\n' 'Multisite blogs:' "$LS_BLOGS"
}

_save_before() {
  B_REV=$LS_REV; B_ORPH=$LS_ORPH; B_AUTO=$LS_AUTO; B_TRASH_POST=$LS_TRASH_POST
  B_SPAM=$LS_SPAM; B_TRASH_COMMENT=$LS_TRASH_COMMENT; B_TRACK=$LS_TRACK
  B_EXPIRED=$LS_EXPIRED; B_TRANSIENTS=$LS_TRANSIENTS; B_TABLES=$LS_TABLES; B_SIZE=$LS_SIZE
}

_removed() { local before="$1" after="$2"; printf '%s' $((before-after)); }

_action_label() {
  case "$1" in
    clear_posts) printf 'post data (revisions/meta/drafts/trash)' ;;
    clear_comments) printf 'spam + trashed comments' ;;
    clear_trackbacks) printf 'trackbacks + pingbacks' ;;
    clear_transients) printf 'expired + all transients' ;;
    optimize_tables) printf 'database tables' ;;
    *) printf '%s' "$1" ;;
  esac
}

LS_ACTION_TOTAL=0; LS_ACTION_OK=0; LS_ACTION_FAILURES=0; LS_ACTION_BLOGS_DONE=0
_run_actions() {
  local site="$1" multisite="$2" logfile="$3" mode="${4:-all}" ids blog action rc tmp detail blog_failed
  local -a actions=()
  if [ "$mode" = all ]; then
    actions=(clear_posts clear_comments clear_trackbacks clear_transients optimize_tables)
  else
    [ "$LS_REV" -eq 0 ] && [ "$LS_ORPH" -eq 0 ] && [ "$LS_AUTO" -eq 0 ] && [ "$LS_TRASH_POST" -eq 0 ] || actions+=(clear_posts)
    [ "$LS_SPAM" -eq 0 ] && [ "$LS_TRASH_COMMENT" -eq 0 ] || actions+=(clear_comments)
    [ "$LS_TRACK" -eq 0 ] || actions+=(clear_trackbacks)
    [ "$LS_EXPIRED" -eq 0 ] && [ "$LS_TRANSIENTS" -eq 0 ] || actions+=(clear_transients)
    [ "$LS_TABLES" -eq 0 ] || actions+=(optimize_tables)
  fi
  [ "${#actions[@]}" -gt 0 ] || return 0
  if [ "$multisite" = 1 ]; then ids=$(_multisite_blog_ids "$site") || return 96; else ids=''; fi
  if [ "$multisite" = 1 ]; then
    while IFS= read -r blog; do
      [ -n "$blog" ] || continue
      blog_failed=0
      for action in "${actions[@]}"; do
        tmp=$(tmpf); rc=0
        (cd "$site" && wp litespeed-database "$action" blog "$blog") >"$tmp" 2>&1 || rc=$?
        LS_ACTION_TOTAL=$((LS_ACTION_TOTAL+1))
        if [ "$rc" -eq 0 ]; then
          LS_ACTION_OK=$((LS_ACTION_OK+1)); printf 'PWLSACTION\tOK\t%s\t%s\t0\n' "$blog" "$action" >> "$logfile"
        else
          LS_ACTION_FAILURES=$((LS_ACTION_FAILURES+1)); blog_failed=1
          detail=$(head -n1 "$tmp" | tr '\t\r\n' '   ' | cut -c1-160)
          printf 'PWLSACTION\tFAIL\t%s\t%s\t%s\t%s\n' "$blog" "$action" "$rc" "$detail" >> "$logfile"
        fi
        rm -f "$tmp"
      done
      [ "$blog_failed" -ne 0 ] || LS_ACTION_BLOGS_DONE=$((LS_ACTION_BLOGS_DONE+1))
    done <<< "$ids"
  else
    for action in "${actions[@]}"; do
      tmp=$(tmpf); rc=0
      (cd "$site" && wp litespeed-database "$action") >"$tmp" 2>&1 || rc=$?
      LS_ACTION_TOTAL=$((LS_ACTION_TOTAL+1))
      if [ "$rc" -eq 0 ]; then
        LS_ACTION_OK=$((LS_ACTION_OK+1)); printf 'PWLSACTION\tOK\tsingle\t%s\t0\n' "$action" >> "$logfile"
      else
        LS_ACTION_FAILURES=$((LS_ACTION_FAILURES+1))
        detail=$(head -n1 "$tmp" | tr '\t\r\n' '   ' | cut -c1-160)
        printf 'PWLSACTION\tFAIL\tsingle\t%s\t%s\t%s\n' "$action" "$rc" "$detail" >> "$logfile"
      fi
      rm -f "$tmp"
    done
    [ "$LS_ACTION_FAILURES" -ne 0 ] || LS_ACTION_BLOGS_DONE=1
  fi
  [ "$LS_ACTION_FAILURES" -eq 0 ]
}

_print_action_log() {
  local logfile="$1" phase="$2" rec state blog action rc detail prefix label
  printf '    %s\n' "$phase"
  while IFS=$'\t' read -r rec state blog action rc detail; do
    [ "$rec" = PWLSACTION ] || continue
    label=$(_action_label "$action")
    if [ "$blog" = single ]; then prefix=''; else prefix="Blog $blog • "; fi
    if [ "$state" = OK ]; then
      printf '      ✓ %s%s command completed\n' "$prefix" "$label"
    else
      printf '      ✖ %s%s failed (exit %s)' "$prefix" "$label" "$rc"
      [ -z "${detail:-}" ] || printf ' • %s' "$detail"
      printf '\n'
    fi
  done < "$logfile"
}

_preflight_site() {
  local site="$1" ids count
  # Active sites take the fast path: one plugin-active check, one LiteSpeed
  # database-family probe, and multisite detection. Only failures need the
  # extra bootstrap/install calls required to distinguish unavailable states.
  if ! _lscwp_active "$site"; then
    if ! _wp_bootstrap_ok "$site"; then printf 'ERROR\tWordPress/WP-CLI bootstrap failed\n'; return 0; fi
    if ! _lscwp_installed "$site"; then printf 'SKIP\tLiteSpeed Cache is not installed\n'; return 0; fi
    printf 'SKIP\tLiteSpeed Cache is installed but inactive\n'
    return 0
  fi
  if ! _lscwp_commands_available "$site"; then printf 'ERROR\tLiteSpeed database command family is unavailable\n'; return 0; fi
  if _is_multisite "$site"; then
    ids=$(_multisite_blog_ids "$site") || { printf 'ERROR\tmultisite blog-ID inventory failed; no cleanup will be attempted\n'; return 0; }
    count=$(printf '%s\n' "$ids" | awk 'NF { n++ } END { print n+0 }')
    printf 'READY\tmultisite detected; %s validated blog(s)\n' "$count"
  else
    printf 'READY\tLiteSpeed database commands available\n'
  fi
}

_confirm_optimize() {
  local count="$1" ans=''
  [ "${PRESSGARDEN_INTERACTIVE:-1}" = 0 ] && return 0
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '\n  Run verified LiteSpeed database maintenance across up to %s discovered WordPress installation(s) under %s? Ineligible sites will be skipped. [y/N]: ' "$count" "$ROOT" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=''
    case "$ans" in y|Y|yes|YES) return 0 ;; *) printf 'Cancelled.\n'; return 1 ;; esac
  fi
  printf 'Refusing LiteSpeed database maintenance without an interactive terminal. Set PRESSGARDEN_INTERACTIVE=0 only for intentional automation.\n' >&2
  return 1
}

LSDB_PHASE=''
_lsdb_interrupt() {
  trap - INT TERM
  if [ "$LSDB_PHASE" = preflight ] || [ "$LSDB_PHASE" = status ]; then
    printf '\nInterrupted during LiteSpeed database inspection; no databases were changed.\n' >&2
  elif [ "$LSDB_PHASE" = optimize ]; then
    printf '\nInterrupted during LiteSpeed database maintenance; actions already completed remain applied. Run a fresh DB maintenance pass to verify current state.\n' >&2
  else
    printf '\nLiteSpeed database operation interrupted.\n' >&2
  fi
  exit 130
}

_status() {
  local site label row state detail idx=0 total is_multi pending=0 already=0 skipped=0 failed=0
  require_wp; discover_sites; total=${#WP_SITES[@]}
  trap _lsdb_interrupt INT TERM; LSDB_PHASE=status
  printf 'LiteSpeed database status — %s discovered WordPress installation(s)\n' "$total"
  printf 'Counters come from LiteSpeed DB_Optm::db_count(), the same source used by wp-admin/admin.php?page=litespeed-db_optm.\n\n'
  for site in "${WP_SITES[@]}"; do
    pg_unlock_site
    pg_lock_site "$site" || { failed=$((failed+1)); continue; }
    idx=$((idx+1)); label=$(site_label_from_root "$site"); row=$(_preflight_site "$site"); IFS=$'\t' read -r state detail <<< "$row"
    case "$state" in
      SKIP) skipped=$((skipped+1)); printf '[%3d/%3d] %-34s\n    RESULT  - UNAVAILABLE • %s\n\n' "$idx" "$total" "$label" "$detail"; continue ;;
      ERROR) failed=$((failed+1)); printf '[%3d/%3d] %-34s\n    RESULT  ✖ ERROR • %s\n\n' "$idx" "$total" "$label" "$detail"; continue ;;
    esac
    is_multi=0; [[ "$detail" == multisite* ]] && is_multi=1
    printf '[%3d/%3d] %s\n' "$idx" "$total" "$label"
    if ! _capture_install_state "$site" "$is_multi"; then
      failed=$((failed+1)); printf '    RESULT\n      ✖ ERROR  LiteSpeed database state could not be read; no clean verdict.\n\n'; continue
    fi
    _print_state 'CURRENT'
    if _state_pending; then pending=$((pending+1)); printf '    RESULT\n      ⚠ CLEANUP AVAILABLE  One or more LiteSpeed dashboard counters are non-zero.\n\n'
    else already=$((already+1)); printf '    RESULT\n      ✓ ALREADY OPTIMIZED  All LiteSpeed dashboard counters are zero.\n\n'; fi
  done
  pg_unlock_site
  trap - INT TERM; LSDB_PHASE=''
  printf 'LiteSpeed Database Status Summary\n'
  printf '  Websites checked:       %s\n' "$total"
  printf '  Already optimized:      %s\n' "$already"
  printf '  Cleanup available:      %s\n' "$pending"
  printf '  LiteSpeed unavailable:  %s\n' "$skipped"
  printf '  Errors:                 %s\n' "$failed"
  [ "$failed" -eq 0 ] || return 2
}

_optimize() {
  local site label row state detail is_multi idx=0 total log retrylog
  local ready=0 unavailable=0 preflight_failed=0 verified=0 already=0 unverified=0 failed=0
  local pair_n=0 pair_before=0 pair_after=0
  local tr=0 to=0 ta=0 tt=0 ts=0 tc=0 tk=0 te=0 tx=0 tb=0
  local dr do_ da dt ds dc dk de dx db
  require_wp; discover_sites; total=${#WP_SITES[@]}
  trap _lsdb_interrupt INT TERM; LSDB_PHASE=preflight
  printf 'LiteSpeed verified database maintenance — %s discovered WordPress installation(s)\n' "$total"
  printf 'Verification: LiteSpeed dashboard counters BEFORE → documented cleanup commands → counters AFTER.\n'
  printf 'Execution: streaming per installation; each site is preflighted and processed immediately.\n'
  printf '\n'

  pg_mutation_preflight || return 2
  _confirm_optimize "$total" || { trap - INT TERM; LSDB_PHASE=''; return 1; }

  # Once fleet processing begins, earlier installations may already have been
  # changed while a later installation is being preflighted. Treat any
  # interruption as an interrupted maintenance pass, never as a no-change event.
  LSDB_PHASE=optimize
  printf '\nProcessing verified LiteSpeed database maintenance sequentially...\n\n'
  for site in "${WP_SITES[@]}"; do
    idx=$((idx+1)); label=$(site_label_from_root "$site")
    printf '[%3d/%3d] %s\n' "$idx" "$total" "$label"

    row=$(_preflight_site "$site"); IFS=$'\t' read -r state detail <<< "$row"
    case "$state" in
      SKIP)
        unavailable=$((unavailable+1))
        printf '    PRECHECK\n      - UNAVAILABLE  %s\n' "$detail"
        printf '    RESULT\n      - SKIPPED  Native PressGarden DB maintenance can still run independently.\n\n'
        continue
        ;;
      ERROR)
        preflight_failed=$((preflight_failed+1))
        printf '    PRECHECK\n      ✖ ERROR  %s\n' "$detail"
        printf '    RESULT\n      ✖ FAILED  LiteSpeed database maintenance did not start for this installation.\n\n'
        continue
        ;;
      READY)
        ready=$((ready+1))
        printf '    PRECHECK\n      ✓ %s\n' "$detail"
        ;;
      *)
        preflight_failed=$((preflight_failed+1))
        printf '    PRECHECK\n      ✖ ERROR  unexpected preflight state\n'
        printf '    RESULT\n      ✖ FAILED  LiteSpeed database maintenance did not start for this installation.\n\n'
        continue
        ;;
    esac

    is_multi=0; [[ "$detail" == multisite* ]] && is_multi=1
    if ! _capture_install_state "$site" "$is_multi"; then
      failed=$((failed+1)); printf '    BEFORE\n      ✖ ERROR  Could not read LiteSpeed dashboard counters. Database was not changed.\n\n'; continue
    fi
    _save_before; _print_state 'BEFORE'
    if ! _state_pending; then
      already=$((already+1)); printf '    RESULT\n      ✓ ALREADY OPTIMIZED  No LiteSpeed database cleanup was required.\n\n'
      if _is_uint "$B_SIZE"; then pair_n=$((pair_n+1)); pair_before=$((pair_before+B_SIZE)); pair_after=$((pair_after+B_SIZE)); fi
      continue
    fi

    pg_database_backup "$site" || { failed=$((failed+1)); printf "    FAILED: backup precondition; no LiteSpeed cleanup attempted.\n"; continue; }
    log=$(tmpf); : > "$log"; LS_ACTION_TOTAL=0; LS_ACTION_OK=0; LS_ACTION_FAILURES=0; LS_ACTION_BLOGS_DONE=0
    _run_actions "$site" "$is_multi" "$log" all || true
    _print_action_log "$log" 'OPTIMIZING'

    if ! _capture_install_state "$site" "$is_multi"; then
      if [ "$LS_ACTION_FAILURES" -gt 0 ]; then failed=$((failed+1)); printf '    RESULT\n      ✖ FAILED  One or more LiteSpeed commands failed and post-maintenance state could not be verified.\n\n'
      else unverified=$((unverified+1)); printf '    RESULT\n      ⚠ UNVERIFIED  Commands completed, but LiteSpeed database state could not be read afterward.\n\n'; fi
      rm -f "$log"; continue
    fi

    # One bounded targeted pass handles residual counters such as orphaned post
    # meta created by deleting drafts/trash during the first post-data pass.
    if [ "$LS_ACTION_FAILURES" -eq 0 ] && _state_pending; then
      retrylog=$(tmpf); : > "$retrylog"
      _run_actions "$site" "$is_multi" "$retrylog" residual || true
      _print_action_log "$retrylog" 'VERIFYING RESIDUALS'
      rm -f "$retrylog"
      _capture_install_state "$site" "$is_multi" || {
        unverified=$((unverified+1)); printf '    RESULT\n      ⚠ UNVERIFIED  Residual cleanup ran, but final LiteSpeed counters could not be read.\n\n'; rm -f "$log"; continue; }
    fi

    _print_state 'AFTER'
    dr=$(_removed "$B_REV" "$LS_REV"); do_=$(_removed "$B_ORPH" "$LS_ORPH"); da=$(_removed "$B_AUTO" "$LS_AUTO"); dt=$(_removed "$B_TRASH_POST" "$LS_TRASH_POST")
    ds=$(_removed "$B_SPAM" "$LS_SPAM"); dc=$(_removed "$B_TRASH_COMMENT" "$LS_TRASH_COMMENT"); dk=$(_removed "$B_TRACK" "$LS_TRACK")
    de=$(_removed "$B_EXPIRED" "$LS_EXPIRED"); dx=$(_removed "$B_TRANSIENTS" "$LS_TRANSIENTS"); db=$(_removed "$B_TABLES" "$LS_TABLES")
    tr=$((tr+dr)); to=$((to+do_)); ta=$((ta+da)); tt=$((tt+dt)); ts=$((ts+ds)); tc=$((tc+dc)); tk=$((tk+dk)); te=$((te+de)); tx=$((tx+dx)); tb=$((tb+db))
    if _is_uint "$B_SIZE" && _is_uint "$LS_SIZE"; then pair_n=$((pair_n+1)); pair_before=$((pair_before+B_SIZE)); pair_after=$((pair_after+LS_SIZE)); fi

    printf '    COUNTER CHANGES (net decrease, not attribution under concurrent writes)\n'
    printf '      %-30s %10s\n' 'Post revisions net decrease:' "$dr"
    printf '      %-30s %10s\n' 'Orphaned post meta net decrease:' "$do_"
    printf '      %-30s %10s\n' 'Auto drafts net decrease:' "$da"
    printf '      %-30s %10s\n' 'Trashed posts net decrease:' "$dt"
    printf '      %-30s %10s\n' 'Spam comments net decrease:' "$ds"
    printf '      %-30s %10s\n' 'Trashed comments net decrease:' "$dc"
    printf '      %-30s %10s\n' 'Trackbacks/Pingbacks net decrease:' "$dk"
    printf '      %-30s %10s\n' 'Expired transient timers net decrease:' "$de"
    printf '      %-30s %10s\n' 'Transient rows net decrease:' "$dx"
    printf '      %-30s %10s\n' 'Overhead-table net decrease:' "$db"
    if _is_uint "$B_SIZE" && _is_uint "$LS_SIZE"; then
      printf '      %-30s %s → %s' 'DB allocation estimate:' "$(_format_bytes "$B_SIZE")" "$(_format_bytes "$LS_SIZE")"
      if [ "$B_SIZE" -gt "$LS_SIZE" ]; then printf ' • reduction %s' "$(_format_bytes $((B_SIZE-LS_SIZE)))"; elif [ "$B_SIZE" -lt "$LS_SIZE" ]; then printf ' • increase %s' "$(_format_bytes $((LS_SIZE-B_SIZE)))"; else printf ' • no allocation change'; fi
      printf '\n'
    fi

    if [ "$LS_ACTION_FAILURES" -gt 0 ]; then
      failed=$((failed+1)); printf '    RESULT\n      ✖ FAILED  %s LiteSpeed command(s) failed; final counters are shown above.\n\n' "$LS_ACTION_FAILURES"
    elif _state_pending; then
      unverified=$((unverified+1)); printf '    RESULT\n      ⚠ UNVERIFIED  Commands completed, but one or more LiteSpeed dashboard counters remain non-zero.\n      The site is not reported as optimized because the resulting database state was not fully confirmed.\n\n'
    else
      verified=$((verified+1)); printf '    RESULT\n      ✓ VERIFIED  LiteSpeed database maintenance confirmed; all dashboard counters are zero.\n\n'
    fi
    rm -f "$log"
  done

  pg_unlock_site
  trap - INT TERM; LSDB_PHASE=''
  failed=$((failed+preflight_failed))
  printf 'LiteSpeed Database Maintenance Summary\n\n'
  printf '  Websites checked:          %8s\n' "$total"
  printf '  Eligible processed:        %8s\n' "$ready"
  printf '  Optimized + verified:      %8s\n' "$verified"
  printf '  Already optimized:         %8s\n' "$already"
  printf '  LiteSpeed unavailable:     %8s\n' "$unavailable"
  printf '  Unverified:                %8s\n' "$unverified"
  printf '  Failed:                    %8s\n' "$failed"
  if [ "$pair_n" -gt 0 ]; then
    printf '\n  Database before:            %8s\n' "$(_format_bytes "$pair_before")"
    printf '  Database after:             %8s\n' "$(_format_bytes "$pair_after")"
    if [ "$pair_before" -gt "$pair_after" ]; then printf '  Estimated reduction:         %8s\n' "$(_format_bytes $((pair_before-pair_after)))"; elif [ "$pair_before" -lt "$pair_after" ]; then printf '  Reported increase:          %8s\n' "$(_format_bytes $((pair_after-pair_before)))"; else printf '  Reported allocation change: %8s\n' '0 B'; fi
    printf '  Size pairs measured:        %8s\n' "$pair_n"
  fi
  printf '\n  Post revisions net decrease:     %8s\n' "$tr"
  printf '  Orphaned post meta net decrease: %8s\n' "$to"
  printf '  Auto drafts net decrease:        %8s\n' "$ta"
  printf '  Trashed posts net decrease:      %8s\n' "$tt"
  printf '  Spam comments net decrease:      %8s\n' "$ts"
  printf '  Trashed comments net decrease:   %8s\n' "$tc"
  printf '  Trackbacks/Pingbacks:       %8s\n' "$tk"
  printf '  Expired transient timers:   %8s\n' "$te"
  printf '  Transient rows net decrease:     %8s\n' "$tx"
  printf '  Overhead-table net decrease:           %8s\n' "$tb"
  printf '\nNote: expired-transient timers are a subset of transient rows, so those two removal figures overlap and must not be added together.\n'
  printf 'Database size is allocation telemetry only; verification is based on LiteSpeed dashboard counters, not size reduction.\n'
  [ "$failed" -eq 0 ] && [ "$unverified" -eq 0 ] || return 2
}

case "$ACTION" in
  status) _status ;;
  optimize) _optimize ;;
esac
