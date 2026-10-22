<?php
/** WP-CLI read-only scope check; bootstrap still executes trusted WordPress code. */
function pg_ls_purge_id($value): int {
    if (!is_string($value) || !preg_match('/^[1-9][0-9]{0,9}$/D', $value)
        || (string)(int)$value !== $value) throw new RuntimeException('invalid blog/network identifier');
    return (int)$value;
}
function pg_ls_purge_scope(array $args): string {
    if (count($args) !== 3 || !in_array($args[0], ['all','blog'], true)
        || !in_array($args[2], ['0','1'], true)) throw new RuntimeException('invalid purge scope request');
    [$action,$blog,$network] = $args;
    $multi = is_multisite();
    if (!is_bool($multi)) throw new RuntimeException('multisite state unavailable');
    $current = pg_ls_purge_id((string)get_current_blog_id());
    $networkId = $multi ? pg_ls_purge_id((string)get_current_network_id()) : 0;
    if ($action === 'all') {
        if ($multi && $network !== '1') throw new RuntimeException('network-wide purge needs explicit --network; use purge blog ID for one blog');
        return $multi ? 'network:'.$networkId : 'single:'.$current;
    }
    $id = pg_ls_purge_id($blog);
    if (!$multi) {
        if ($id !== $current) throw new RuntimeException('blog does not belong to selected installation');
        return 'single:'.$current;
    }
    $site = get_site($id);
    if (!$site || (int)$site->site_id !== $networkId || (int)$site->blog_id !== $id
        || !empty($site->deleted) || !empty($site->archived) || !empty($site->spam)) {
        throw new RuntimeException('blog is absent, inactive or outside the selected network');
    }
    return 'blog:'.$networkId.':'.$id;
}
if (!defined('PG_PURGE_SCOPE_TEST')) {
    try { echo pg_ls_purge_scope($args ?? []), "\n"; }
    catch (Throwable $e) { fwrite(STDERR, 'PURGE REFUSED: '.$e->getMessage()."; no purge performed.\n"); exit(2); }
}
