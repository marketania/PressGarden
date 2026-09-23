<?php
/** PressGarden update input validation (MIT). Never executes archive contents. */
function pg_update_octal($field) {
    $field = trim($field, " \0");
    if ($field === '') return 0;
    if (!preg_match('/^[0-7]{1,12}$/D', $field)) throw new RuntimeException('unsupported tar numeric field');
    $value = octdec($field);
    if ($value > PHP_INT_MAX) throw new RuntimeException('tar numeric field overflow');
    return (int)$value;
}
function pg_update_read($stream, $length) {
    $out = '';
    while (strlen($out) < $length) {
        $part = @gzread($stream, $length - strlen($out));
        if ($part === false || $part === '') throw new RuntimeException('truncated gzip/tar stream');
        $out .= $part;
    }
    return $out;
}
function pg_update_pax($data) {
    // git archive uses a global PAX comment containing the source commit.
    // Do not let metadata override names, sizes, links, or sparse-file behavior.
    while ($data !== '') {
        if (!preg_match('/^([1-9][0-9]{0,5}) /', $data, $m)) throw new RuntimeException('invalid PAX record');
        $length = (int)$m[1];
        if ($length <= strlen($m[0]) || $length > strlen($data)) throw new RuntimeException('invalid PAX length');
        $record = substr($data, strlen($m[0]), $length - strlen($m[0]));
        if (substr($record, -1) !== "\n" || !preg_match('/^(comment|mtime|atime|ctime)=[^\x00-\x1f]*\n$/D', $record)) {
            throw new RuntimeException('unsupported PAX metadata');
        }
        $data = substr($data, $length);
    }
}
function pg_update_archive($path) {
    if (!function_exists('gzopen')) throw new RuntimeException('PHP zlib is required for archive validation');
    if (!is_file($path) || !is_readable($path) || filesize($path) > 33554432) throw new RuntimeException('archive missing, unreadable, or larger than 32 MiB');
    $stream = @gzopen($path, 'rb');
    if ($stream === false) throw new RuntimeException('cannot read gzip archive');
    $total = 0; $entries = 0; $root = null; $seen = []; $parents = []; $zero = str_repeat("\0", 512);
    try {
        while (true) {
            $header = pg_update_read($stream, 512); $total += 512;
            if ($header === $zero) {
                if (pg_update_read($stream, 512) !== $zero) throw new RuntimeException('invalid tar end marker');
                $total += 512;
                // Reject concatenated archives and nonzero data after the terminator.
                while (!gzeof($stream)) {
                    $tail = @gzread($stream, 65536);
                    if ($tail === false || ($tail === '' && !gzeof($stream))) throw new RuntimeException('invalid gzip trailer');
                    $total += strlen($tail);
                    if ($total > 134217728 || trim($tail, "\0") !== '') throw new RuntimeException('unexpected archive trailer or size limit');
                }
                if ($entries === 0 || $root === null) throw new RuntimeException('empty archive');
                return;
            }
            if (++$entries > 10000) throw new RuntimeException('archive entry limit exceeded');
            $sum = array_sum(unpack('C*', substr_replace($header, str_repeat(' ', 8), 148, 8)));
            if ($sum !== pg_update_octal(substr($header, 148, 8))) throw new RuntimeException('invalid tar header checksum');
            $magic = substr($header, 257, 6);
            if ($magic !== "ustar\0" && $magic !== 'ustar ') throw new RuntimeException('unsupported tar format');
            $size = pg_update_octal(substr($header, 124, 12));
            $mode = pg_update_octal(substr($header, 100, 8));
            if ($size > 16777216 || ($mode & 06000) !== 0) throw new RuntimeException('oversized member or privileged mode');
            $type = $header[156];
            $blocks = (int)(ceil($size / 512) * 512); $total += $blocks;
            if ($total > 134217728) throw new RuntimeException('expanded archive exceeds 128 MiB');
            if ($type === 'g' || $type === 'x') {
                if ($size > 65536) throw new RuntimeException('PAX metadata limit exceeded');
                pg_update_pax(substr(pg_update_read($stream, $blocks), 0, $size));
                continue;
            }
            if ($type !== '0' && $type !== "\0" && $type !== '5') throw new RuntimeException('links, devices, sparse files, and special entries are not permitted');
            if ($type === '5' && $size !== 0) throw new RuntimeException('directory with data');
            if (trim(substr($header, 157, 100), "\0") !== '') throw new RuntimeException('unexpected tar link target');
            $name = rtrim(substr($header, 0, 100), "\0");
            $prefix = rtrim(substr($header, 345, 155), "\0");
            if ($magic === "ustar\0" && $prefix !== '') $name = $prefix.'/'.$name;
            elseif ($magic === 'ustar ' && $prefix !== '') throw new RuntimeException('unsupported GNU header extension');
            if ($type === '5') $name = rtrim($name, '/');
            if ($name === '' || $name[0] === '/' || preg_match('/[\x00-\x1f\x7f\\\\]/', $name)) throw new RuntimeException('unsafe archive name');
            $parts = explode('/', $name);
            foreach ($parts as $part) if ($part === '' || $part === '.' || $part === '..') throw new RuntimeException('unsafe archive path component');
            if ($root === null) $root = $parts[0];
            if ($parts[0] !== $root || (count($parts) === 1 && $type !== '5')) throw new RuntimeException('archive must have one top-level directory');
            if (isset($seen[$name]) || ($type !== '5' && isset($parents[$name]))) throw new RuntimeException('duplicate/conflicting archive path');
            $parent = $name;
            while (($pos = strrpos($parent, '/')) !== false) {
                $parent = substr($parent, 0, $pos);
                if (isset($seen[$parent]) && $seen[$parent] !== '5') throw new RuntimeException('non-directory archive parent');
                $parents[$parent] = true;
            }
            $seen[$name] = $type;
            while ($blocks > 0) { $read = min(65536, $blocks); pg_update_read($stream, $read); $blocks -= $read; }
        }
    } finally { gzclose($stream); }
}
function pg_update_canonical($path) {
    if ($path === '') return '';
    if ($path[0] !== '/') $path = getcwd().'/'.$path;
    $out = '';
    foreach (explode('/', $path) as $part) {
        if ($part === '' || $part === '.') continue;
        if ($part === '..') { $out = dirname($out === '' ? '/' : $out); continue; }
        $next = rtrim($out, '/').'/'.$part;
        if (file_exists($next) || is_link($next)) {
            $real = realpath($next);
            if ($real === false) throw new RuntimeException('cannot resolve private path');
            $out = $real;
        } else $out = $next;
    }
    return $out === '' ? '/' : $out;
}
function pg_update_layout($args) {
    $target = array_shift($args); $managed = []; $private = false;
    foreach ($args as $arg) {
        if ($arg === '--private') { $private = true; continue; }
        if (!$private) { $managed[] = $target.'/'.$arg; continue; }
        if ($arg === '') continue;
        $path = pg_update_canonical($arg);
        foreach ($managed as $owned) {
            if ($path === $owned || strpos($path, $owned.'/') === 0) throw new RuntimeException('private data overlaps managed code; move it outside program paths before updating');
        }
    }
}
if (isset($argv) && realpath($argv[0]) === __FILE__) {
    try {
        if (($argv[1] ?? '') === 'archive' && $argc === 3) pg_update_archive($argv[2]);
        elseif (($argv[1] ?? '') === 'layout' && $argc >= 5) pg_update_layout(array_slice($argv, 2));
        else throw new RuntimeException('invalid update guard arguments');
    } catch (Throwable $e) { fwrite(STDERR, 'Update validation failed: '.$e->getMessage().".\n"); exit(2); }
}
