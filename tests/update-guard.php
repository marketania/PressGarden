<?php
require __DIR__.'/../lib/update-guard.php';
$dir = sys_get_temp_dir().'/pressgarden-guard-'.bin2hex(random_bytes(8));
if (!mkdir($dir, 0700)) exit(2);
$count = 0;
function entry($name, $body = '', $type = '0', $link = '', $mode = 0644, $size = null) {
    $h = str_repeat("\0", 512);
    foreach ([0=>$name, 100=>sprintf('%07o', $mode), 108=>'0000000', 116=>'0000000', 124=>sprintf('%011o', $size ?? strlen($body)), 136=>'00000000000', 148=>'        ', 156=>$type, 157=>$link, 257=>"ustar\0", 263=>'00'] as $at=>$value) $h = substr_replace($h, $value, $at, strlen($value));
    $h = substr_replace($h, sprintf('%06o', array_sum(unpack('C*', $h)))."\0 ", 148, 8);
    return $h.$body.str_repeat("\0", (512 - strlen($body) % 512) % 512);
}
function pax($value) {
    $n = strlen($value) + 2;
    while (strlen((string)$n) + 1 + strlen($value) !== $n) $n = strlen((string)$n) + 1 + strlen($value);
    return $n.' '.$value;
}
function checkArchive($name, $data, $valid = false, $terminator = true) {
    global $dir, $count;
    $path = $dir.'/input.gz';
    file_put_contents($path, gzencode($data.($terminator ? str_repeat("\0", 1024) : '')));
    $ok = true;
    try { pg_update_archive($path); } catch (RuntimeException $e) { $ok = false; }
    if ($ok !== $valid) throw new RuntimeException('archive case failed: '.$name);
    ++$count;
}
try {
    $root = entry('pkg/', '', '5', '', 0755);
    $good = $root.entry('pkg/VERSION', "1.1.3\n").entry('pkg/lib/x.php', '<?php // data only');
    checkArchive('regular GitHub-style archive', $good, true);
    checkArchive('git global PAX comment', entry('pax_global_header', pax("comment=0123456789abcdef\n"), 'g').$good, true);
    checkArchive('non-overriding per-file PAX time', $root.entry('pax_header', pax("mtime=123.5\n"), 'x').entry('pkg/test', 'x'), true);
    checkArchive('parent traversal', $root.entry('pkg/../escape', 'x'));
    checkArchive('absolute path', $root.entry('/tmp/escape', 'x'));
    checkArchive('backslash path', $root.entry('pkg/..\\escape', 'x'));
    checkArchive('control character path', $root.entry("pkg/a\nb", 'x'));
    checkArchive('embedded NUL path', $root.entry("pkg/a\0b", 'x'));
    checkArchive('extra root', $good.entry('other/x', 'x'));
    checkArchive('top-level file', entry('VERSION', 'x'));
    foreach (['1', '2', '3', '4', '6', 'S', 'L', 'K'] as $type) checkArchive('special type '.$type, $root.entry('pkg/x', '', $type, '../../outside'));
    checkArchive('duplicate name', $good.entry('pkg/VERSION', 'overwrite'));
    checkArchive('parent before child conflict', $root.entry('pkg/file', 'x').entry('pkg/file/child', 'y'));
    checkArchive('child before parent conflict', $root.entry('pkg/file/child', 'x').entry('pkg/file', 'y'));
    checkArchive('PAX path override', entry('pax_global_header', pax("path=../../escape\n"), 'g').$good);
    checkArchive('PAX link override', entry('pax', pax("linkpath=../../escape\n"), 'x').$good);
    checkArchive('PAX size override', entry('pax', pax("size=512\n"), 'x').$good);
    checkArchive('malformed PAX length', entry('pax', "999 comment=x\n", 'g').$good);
    checkArchive('privileged mode', $root.entry('pkg/file', 'x', '0', '', 04755));
    checkArchive('oversized member', $root.entry('pkg/file', '', '0', '', 0644, 16777217));
    checkArchive('truncated member', $root.entry('pkg/file', '', '0', '', 0644, 4096));
    checkArchive('directory with content', entry('pkg/', 'x', '5'));
    checkArchive('bad checksum', substr_replace($good, 'X', 1, 1));
    checkArchive('missing terminator', $good, false, false);
    checkArchive('data after terminator', $good.str_repeat("\0", 1024).'trailer');
    checkArchive('empty archive', '');
    checkArchive('bounded member count', $root.str_repeat(entry('pax', pax("comment=x\n"), 'g'), 10001));
    // A highly compressible archive must still stop at the expanded-byte limit.
    $path = $dir.'/large.gz'; $z = gzopen($path, 'wb'); gzwrite($z, $root);
    for ($i=0; $i<9; ++$i) {
        gzwrite($z, entry('pkg/data'.$i, '', '0', '', 0644, 16777216));
        for ($j=0; $j<256; ++$j) gzwrite($z, str_repeat('A', 65536));
    }
    gzwrite($z, str_repeat("\0", 1024)); gzclose($z);
    $rejected = false; try { pg_update_archive($path); } catch (RuntimeException $e) { $rejected = strpos($e->getMessage(), '128 MiB') !== false; }
    if (!$rejected) throw new RuntimeException('expanded-byte cap failed'); ++$count;
    echo "PressGarden archive guard: $count cases PASS\n";
} finally { foreach (glob($dir.'/*') as $f) unlink($f); rmdir($dir); }
