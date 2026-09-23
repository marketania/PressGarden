# A private SQL dump is mandatory before risky database mutations.
# The dump covers selected tables when supplied, otherwise the configured DB.
pg_database_backup() {
  local site="$1" tables="${2:-}" dir file
  dir=$(pg_safe_backup_dir "$site" database) || return 2
  file="$dir/database.sql"
  local -a args=(db export "$file" --single-transaction --quick --path="$site" --skip-plugins --skip-themes --skip-packages --no-color)
  [ -z "$tables" ] || args+=("--tables=$tables")
  if ! (umask 077; wp "${args[@]}" > "$dir/export.log" 2>&1); then
    printf 'FAILED: database export did not complete; no maintenance attempted. Private diagnostic: %s/export.log\n' "$dir" >&2; return 2
  fi
  php -r 'require $argv[1];$s=pg_ops_regular($argv[2],107374182400);if($s["size"]<16)exit(2);if(!chmod($argv[2],0600))exit(2);' "$PRESSGARDEN_DIR/lib/ops-safety.php" "$file" || { printf 'FAILED: dump is absent/unsafe/empty; no mutation attempted.\n' >&2; return 2; }
  (cd "$dir" && sha256sum database.sql > database.sql.sha256 && sha256sum -c database.sql.sha256 >/dev/null) || return 2
  printf 'BACKUP: %s (checksum verified; restore not tested; nontransactional tables may require a host snapshot)\n' "$file"
}
