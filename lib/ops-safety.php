<?php
/** Small local filesystem safety primitive. PHP 7.4; no application bootstrap. */
function pg_ops_path($path) {
    if (!is_string($path) || $path === '' || $path[0] !== '/' || preg_match('/[\x00-\x1f\x7f]/', $path)) {
        throw new RuntimeException('an absolute, control-character-free path is required');
    }
    $parts = explode('/', $path); $cur = '';
    foreach ($parts as $part) {
        if ($part === '') continue;
        if ($part === '.' || $part === '..') throw new RuntimeException('dot path components are refused');
        $cur .= '/'.$part;
        if (is_link($cur)) throw new RuntimeException('symlink path component refused');
        if (file_exists($cur) && !is_dir($cur)) throw new RuntimeException('non-directory path component refused');
    }
    return rtrim($path, '/');
}
function pg_ops_dir($path) {
    $path = pg_ops_path($path);
    if ($path === '') throw new RuntimeException('filesystem root is not private state');
    if (!is_dir($path)) {
        $mask = umask(0077);
        try { $ok = @mkdir($path, 0700, true); } finally { umask($mask); }
        if (!$ok && !is_dir($path)) throw new RuntimeException('cannot create private directory');
    }
    $stat = @lstat($path);
    if (!$stat || is_link($path) || ($stat['mode'] & 0170000) !== 0040000
        || ($stat['mode'] & 0022) !== 0) throw new RuntimeException('unsafe writable private directory');
    if (function_exists('posix_geteuid') && $stat['uid'] !== posix_geteuid()) {
        throw new RuntimeException('private directory is owned by another account');
    }
    return $path;
}
function pg_ops_scope($state, array $sites) {
    if (!$sites) throw new RuntimeException('no selected WordPress sites');
    $state = pg_ops_path($state);
    foreach ($sites as $site) {
        $site = pg_ops_path($site);
        if (!is_dir($site)) throw new RuntimeException('selected site disappeared');
        if ($state === $site || strpos($state, $site.'/') === 0) {
            throw new RuntimeException('state/backups must be outside every selected website');
        }
        $config = $site.'/wp-config.php';
        $stat = @lstat($config);
        if (!$stat || is_link($config) || ($stat['mode'] & 0170000) !== 0100000 || $stat['nlink'] !== 1) {
            throw new RuntimeException('selected wp-config.php is missing, linked or not a regular file');
        }
    }
    return pg_ops_dir($state);
}
function pg_ops_backup_dir($state, $site, $category) {
    if (!preg_match('/^[a-z][a-z0-9-]{0,50}$/D', $category)) throw new RuntimeException('invalid backup category');
    $state = pg_ops_scope($state, [$site]);
    $parent = pg_ops_dir($state.'/backups');
    $parent = pg_ops_dir($parent.'/'.$category);
    $dir = $parent.'/'.gmdate('Ymd\THis\Z').'-'.substr(hash('sha256', $site),0,12).'-'.bin2hex(random_bytes(8));
    if (!@mkdir($dir, 0700)) throw new RuntimeException('cannot allocate exclusive backup directory');
    return $dir;
}
function pg_ops_regular($file, $max = 4194304) {
    pg_ops_path(dirname($file)); $st = @lstat($file);
    if (!$st || is_link($file) || ($st['mode'] & 0170000) !== 0100000 || $st['nlink'] !== 1 || $st['size'] > $max) {
        throw new RuntimeException('unsafe or oversized regular file');
    }
    return $st;
}
function pg_ops_lock_file($state,$site) {
    $dir=pg_ops_dir(pg_ops_scope($state,[$site]).'/operation-locks');
    $file=$dir.'/'.hash('sha256',$site).'.lock';
    if(!file_exists($file)&&!is_link($file)){ $mask=umask(0077);$h=@fopen($file,'x');umask($mask);if($h)fclose($h); }
    $s=pg_ops_regular($file);
    if(($s['mode']&0077)!==0||(function_exists('posix_geteuid')&&$s['uid']!==posix_geteuid()))throw new RuntimeException('unsafe operation lock ownership/mode');
    return $file;
}
if (isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    try {
        if (($argv[1] ?? '') === 'scope' && $argc >= 4) pg_ops_scope($argv[2], array_slice($argv,3));
        elseif (($argv[1] ?? '') === 'backup-dir' && $argc === 5) echo pg_ops_backup_dir($argv[2],$argv[3],$argv[4]),"\n";
        elseif (($argv[1] ?? '') === 'lock-file' && $argc === 4) echo pg_ops_lock_file($argv[2],$argv[3]),"\n";
        elseif (($argv[1] ?? '') === 'path' && $argc === 3) pg_ops_path($argv[2]);
        elseif (($argv[1] ?? '') === 'directory' && $argc === 3) echo pg_ops_dir($argv[2]),"\n";
        else throw new RuntimeException('invalid safety helper arguments');
    } catch (Throwable $e) { fwrite(STDERR, 'SAFETY: '.$e->getMessage().".\n"); exit(2); }
}
