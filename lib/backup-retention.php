<?php
/** Manual backup retention for PressGarden's own private state. PHP 7.4.
 * Preview never deletes. Only backups with a recorded complete, intact state are
 * eligible, and the newest backup per site and category is always kept. */
require_once __DIR__.'/ops-safety.php';

const PG_RETENTION_MAX_ENTRIES = 20000;

function pg_retention_names($dir) {
    $h = @opendir($dir); if ($h === false) throw new RuntimeException('cannot read backup directory');
    $names = []; $n = 0;
    try {
        while (false !== ($name = readdir($h))) {
            if ($name === '.' || $name === '..') continue;
            if (++$n > PG_RETENTION_MAX_ENTRIES) throw new RuntimeException('backup listing limit');
            $names[] = $name;
        }
    } finally { closedir($h); }
    sort($names, SORT_STRING);
    return $names;
}
/** Walk a backup directory without following links; returns its regular-file bytes. */
function pg_retention_bytes($dir, $depth = 0) {
    if ($depth > 4) throw new RuntimeException('unexpected backup layout');
    $bytes = 0;
    foreach (pg_retention_names($dir) as $name) {
        $p = $dir.'/'.$name; $s = @lstat($p);
        if (!$s) throw new RuntimeException('backup entry disappeared');
        $type = $s['mode'] & 0170000;
        if ($type === 0040000) $bytes += pg_retention_bytes($p, $depth + 1);
        elseif ($type === 0100000 && $s['nlink'] === 1) $bytes += $s['size'];
        else throw new RuntimeException('link or special file in backup');
    }
    return $bytes;
}
function pg_retention_remove($dir, $depth = 0) {
    if ($depth > 4) throw new RuntimeException('unexpected backup layout');
    foreach (pg_retention_names($dir) as $name) {
        $p = $dir.'/'.$name; $s = @lstat($p);
        if (!$s) throw new RuntimeException('backup entry disappeared');
        $type = $s['mode'] & 0170000;
        if ($type === 0040000) pg_retention_remove($p, $depth + 1);
        elseif ($type === 0100000) { if (!@unlink($p)) throw new RuntimeException('backup file removal failed'); }
        else throw new RuntimeException('link or special file in backup');
    }
    if (!@rmdir($dir)) throw new RuntimeException('backup directory removal failed');
}
/** Why a backup is not known complete and intact, or '' when it is. */
function pg_retention_incomplete($category, $dir) {
    if ($category === 'file-cleanup') {
        $meta = $dir.'/manifest.json';
        try { pg_ops_regular($meta, 16777216); } catch (Throwable $e) { return 'manifest missing or unsafe'; }
        $m = json_decode((string)file_get_contents($meta), true);
        if (!is_array($m)) return 'manifest unreadable';
        if (($m['status'] ?? '') !== 'COMPLETED') return 'cleanup status '.preg_replace('/[^A-Z_]/', '', (string)($m['status'] ?? 'unknown'));
        return '';
    }
    if ($category === 'database') {
        $sql = $dir.'/database.sql'; $sum = $dir.'/database.sql.sha256';
        try { pg_ops_regular($sql, 107374182400); pg_ops_regular($sum, 4096); } catch (Throwable $e) { return 'dump or checksum missing'; }
        if (!preg_match('/^([a-f0-9]{64})  database\.sql\n?$/D', (string)file_get_contents($sum), $m)) return 'checksum file unreadable';
        if (!hash_equals($m[1], (string)hash_file('sha256', $sql))) return 'checksum mismatch';
        return '';
    }
    return 'no completion record for this category; prune it manually';
}
function pg_retention_plan($state, $days, $now = null) {
    if (!is_int($days) || $days < 1 || $days > 36500) throw new RuntimeException('invalid retention days');
    $state = pg_ops_path($state); $root = $state.'/backups';
    $out = ['eligible'=>[], 'kept'=>[], 'root'=>$root];
    if (!file_exists($root) && !is_link($root)) return $out;
    pg_ops_path($root);
    if (is_link($root) || !is_dir($root)) throw new RuntimeException('unsafe backup root');
    $cutoff = ($now ?? time()) - $days * 86400;
    foreach (pg_retention_names($root) as $category) {
        $cdir = $root.'/'.$category;
        if (!preg_match('/^[a-z][a-z0-9-]{0,50}$/D', $category) || is_link($cdir) || !is_dir($cdir)) continue;
        $groups = [];
        foreach (pg_retention_names($cdir) as $name) {
            if (!preg_match('/^([0-9]{8}T[0-9]{6}Z)-([a-f0-9]{12})-[a-f0-9]{16}$/D', $name, $m)) continue;
            $groups[$m[2]][$name] = $m[1];
        }
        foreach ($groups as $entries) {
            ksort($entries, SORT_STRING);
            $newest = array_key_last($entries);
            foreach ($entries as $name => $stamp) {
                $id = $category.'/'.$name; $dir = $cdir.'/'.$name;
                $t = DateTime::createFromFormat('!Ymd\THis\Z', $stamp, new DateTimeZone('UTC'));
                if ($t === false || $t->getTimestamp() > $cutoff) continue;
                if ($name === $newest) { $out['kept'][$id] = 'newest backup for this site and category'; continue; }
                if (is_link($dir) || !is_dir($dir)) { $out['kept'][$id] = 'not a plain directory'; continue; }
                $why = pg_retention_incomplete($category, $dir);
                if ($why !== '') { $out['kept'][$id] = $why; continue; }
                try { $out['eligible'][$id] = pg_retention_bytes($dir); }
                catch (Throwable $e) { $out['kept'][$id] = $e->getMessage(); }
            }
        }
    }
    ksort($out['eligible'], SORT_STRING); ksort($out['kept'], SORT_STRING);
    return $out;
}
/** Remove exactly the previewed IDs after recomputing eligibility. */
function pg_retention_apply($state, $days, array $approved, $now = null) {
    $plan = pg_retention_plan($state, $days, $now);
    $ids = array_keys($plan['eligible']); sort($approved, SORT_STRING);
    if (!$approved || $ids !== $approved) throw new RuntimeException('eligible backups changed since preview; nothing removed');
    $root = pg_ops_dir($plan['root']); $log = $root.'/prune-log.tsv';
    if (is_link($log) || (file_exists($log) && !is_file($log))) throw new RuntimeException('unsafe prune log');
    $removed = 0; $bytes = 0;
    foreach ($ids as $id) {
        list($category, $name) = explode('/', $id, 2);
        $dir = $root.'/'.$category.'/'.$name; $work = $root.'/'.$category.'/.pruning-'.$name;
        if (file_exists($work) || is_link($work)) throw new RuntimeException('stale prune work directory');
        // Rename first so a partial removal never looks like a usable backup.
        if (!@rename($dir, $work)) throw new RuntimeException('cannot reserve backup for pruning');
        pg_retention_remove($work);
        clearstatcache();
        if (file_exists($work) || is_link($work) || file_exists($dir)) throw new RuntimeException('backup still present after pruning');
        $mask = umask(0077);
        $ok = @file_put_contents($log, gmdate('c')."\t".$id."\t".$plan['eligible'][$id]."\tpruned\n", FILE_APPEND | LOCK_EX);
        umask($mask);
        if ($ok === false) throw new RuntimeException('prune log write failed');
        ++$removed; $bytes += $plan['eligible'][$id];
        printf("PRUNED  %s  %d bytes\n", $id, $plan['eligible'][$id]);
    }
    return ['removed'=>$removed, 'bytes'=>$bytes];
}
if (isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    try {
        $mode = $argv[1] ?? '';
        if (!in_array($mode, ['preview','apply'], true) || !preg_match('/^[1-9][0-9]{0,4}$/D', $argv[3] ?? '')) throw new RuntimeException('invalid arguments');
        if ($mode === 'preview' && $argc === 4) {
            $p = pg_retention_plan($argv[2], (int)$argv[3]);
            foreach ($p['eligible'] as $id => $b) printf("ELIGIBLE\t%s\t%d\n", $id, $b);
            foreach ($p['kept'] as $id => $why) printf("KEPT\t%s\t%s\n", $id, $why);
        } elseif ($mode === 'apply' && $argc === 5) {
            pg_ops_regular($argv[4], 4194304);
            $ids = array_values(array_filter(explode("\n", (string)file_get_contents($argv[4])), 'strlen'));
            foreach ($ids as $id) if (!preg_match('~^[a-z][a-z0-9-]{0,50}/[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}-[a-f0-9]{16}$~D', $id)) throw new RuntimeException('invalid approval list');
            $r = pg_retention_apply($argv[2], (int)$argv[3], $ids);
            printf("Backups removed: %d; logical bytes removed: %d.\n", $r['removed'], $r['bytes']);
            echo "Logical removed bytes are not a claim of net disk space reclaimed.\n";
        } else throw new RuntimeException('invalid arguments');
    } catch (Throwable $e) {
        fwrite(STDERR, 'FAILED: '.$e->getMessage().". Backups were retained unless listed as PRUNED.\n");
        exit(2);
    }
}
