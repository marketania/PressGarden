<?php
// Read-only LiteSpeed database-optimizer state probe for `wp eval-file`.
// The counters intentionally come from LiteSpeed DB_Optm::db_count(), the
// same implementation used by LiteSpeed Cache > Database > Manage.
// PHP 7.4 compatible.

defined('ABSPATH') || exit(70);

function pg_lsdb_fail($code) {
    echo "PWLSDB1\tERROR\t", preg_replace('/[^A-Za-z0-9_.:-]+/', '_', (string) $code), "\n";
    exit(71);
}

$blog_raw = getenv('PRESSGARDEN_LSDB_BLOG');
$blog_id = 0;
$switched = false;

if ($blog_raw !== false && $blog_raw !== '') {
    if (!preg_match('/^[1-9][0-9]*$/D', $blog_raw)) {
        pg_lsdb_fail('invalid_blog_id');
    }
    $blog_id = (int) $blog_raw;
    if (!is_multisite() || !get_blog_details($blog_id)) {
        pg_lsdb_fail('unknown_blog_id');
    }
    if (get_current_blog_id() !== $blog_id) {
        if (!switch_to_blog($blog_id)) {
            pg_lsdb_fail('switch_blog_failed');
        }
        $switched = true;
    }
}

if (!class_exists('\\LiteSpeed\\DB_Optm')) {
    if ($switched) {
        restore_current_blog();
    }
    pg_lsdb_fail('litespeed_db_optimizer_unavailable');
}

try {
    $db = \LiteSpeed\DB_Optm::cls();
    $types = array(
        'revision',
        'orphaned_post_meta',
        'auto_draft',
        'trash_post',
        'spam_comment',
        'trash_comment',
        'trackback-pingback',
        'expired_transient',
        'all_transients',
        'optimize_tables',
    );

    $counts = array();
    foreach ($types as $type) {
        $value = $db->db_count($type, true);
        if (!is_numeric($value) || (int) $value < 0) {
            throw new RuntimeException('invalid_counter');
        }
        $counts[] = (int) $value;
    }

    global $wpdb;
    $wpdb->last_error = '';
    $size = $wpdb->get_var(
        $wpdb->prepare(
            'SELECT COALESCE(SUM(data_length + index_length),0) FROM information_schema.tables WHERE table_schema = %s',
            DB_NAME
        )
    );
    if ($wpdb->last_error || !is_numeric($size) || (int) $size < 0) {
        $size = '-';
    } else {
        $size = (string) (int) $size;
    }

    $effective_blog = (int) get_current_blog_id();
    echo "PWLSDB1\tOK\t", $effective_blog, "\t", implode("\t", $counts), "\t", $size, "\n";
} catch (Throwable $e) {
    if ($switched) {
        restore_current_blog();
        $switched = false;
    }
    pg_lsdb_fail('state_probe_failed');
}

if ($switched) {
    restore_current_blog();
}
