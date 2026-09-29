<?php
/** Bounded inert provider display/readback. Does not bootstrap WordPress. */
require_once __DIR__.'/ops-safety.php';

function pg_ls_sensitive($key) {
    return preg_match('/api.?key|domain.?key|token|secret|password|passwd|private.?key|ssl.?key|credential|authorization|cookie/i', (string)$key);
}
function pg_ls_redact($value) {
    if (!is_array($value)) return $value;
    $out = [];
    foreach ($value as $key => $item) $out[$key] = pg_ls_sensitive($key) ? '[REDACTED]' : pg_ls_redact($item);
    return $out;
}
function pg_ls_snapshot($stat) {
    if (!is_array($stat)) throw new RuntimeException('Unreadable source identity');
    $out = [];
    foreach (['dev','ino','mode','uid','gid','nlink','size','mtime','ctime'] as $key) $out[$key] = $stat[$key];
    return $out;
}
function pg_ls_read_file($file, $limit) {
    clearstatcache();
    $before = pg_ls_snapshot(pg_ops_regular($file, $limit));
    $handle = @fopen($file, 'rb');
    if ($handle === false) throw new RuntimeException('Unreadable provider output');
    try {
        if (pg_ls_snapshot(fstat($handle)) !== $before) throw new RuntimeException('Source changed on open');
        $text = stream_get_contents($handle, $limit + 1);
        clearstatcache();
        if ($text === false || strlen($text) > $limit || strlen($text) !== $before['size']
            || pg_ls_snapshot(fstat($handle)) !== $before
            || pg_ls_snapshot(pg_ops_regular($file, $limit)) !== $before) {
            throw new RuntimeException('Incomplete or changed provider output');
        }
        return $text;
    } finally { fclose($handle); }
}
function pg_ls_display_text($text) {
    if (preg_match('//u', $text) !== 1) {
        return preg_replace_callback('/[\x00-\x1f\x7f-\xff]/', function ($match) {
            return sprintf('\\x%02X', ord($match[0]));
        }, $text);
    }
    return preg_replace_callback('/[\x00-\x1f\x7f-\x9f\x{061c}\x{200e}\x{200f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/u', function ($match) {
        return strlen($match[0]) === 1 ? sprintf('\\x%02X', ord($match[0])) : substr(json_encode($match[0]), 1, -1);
    }, $text);
}
function pg_ls_render($text, $mode) {
    $parsed = json_decode($text, true);
    if (is_array($parsed)) {
        $text = json_encode(pg_ls_redact($parsed), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        if ($text === false) throw new RuntimeException('Redaction failed');
    }
    // No unbounded explode(): many tiny lines must not amplify memory usage.
    $cap = $mode === 'bounded' ? 20 : 10000;
    $offset = 0; $count = 0; $length = strlen($text);
    while ($offset < $length && $count < $cap) {
        $newline = strpos($text, "\n", $offset);
        $end = $newline === false ? $length : $newline;
        $line = substr($text, $offset, $end - $offset);
        $offset = $newline === false ? $length : $end + 1;
        ++$count;
        if (!is_array($parsed) && pg_ls_sensitive($line)) $line = '[REDACTED sensitive response line]';
        $truncated = strlen($line) > 4096;
        $line = pg_ls_display_text(substr($line, 0, 4096));
        if ($line === null) throw new RuntimeException('Display failed');
        if (strlen($line) > 4096) {
            $truncated = true; $line = substr($line, 0, 4096);
            while ($line !== '' && preg_match('//u', $line) !== 1) $line = substr($line, 0, -1);
        }
        echo $line, $truncated ? ' ... [display truncated]' : '', "\n";
    }
    if ($offset < $length) echo "[Additional provider output omitted by display limit]\n";
}

try {
    $mode = $argv[1] ?? '';
    if ($mode === 'verify') {
        if ($argc !== 3) throw new RuntimeException('Invalid readback request');
        $actual = pg_ls_read_file($argv[2], 1048576);
        $expected = stream_get_contents(STDIN, 1048577);
        if ($expected === false || strlen($expected) > 1048576) throw new RuntimeException('Expected value too large');
        // LiteSpeed CLI get: booleans 1/0, empty scalar ''. Keep established normalization.
        $actual = rtrim(str_replace("\r\n", "\n", $actual), "\n");
        $expected = rtrim(str_replace("\r\n", "\n", $expected), "\n");
        if (in_array($expected, ['true','false'], true)) {
            $expected = $expected === 'true' ? '1' : '0';
            if ($actual === 'true') $actual = '1';
            if ($actual === 'false') $actual = '0';
        }
        if ($expected === '' && $actual === "''") $actual = '';
        exit(hash_equals($expected, $actual) ? 0 : 2);
    }
    if ($mode === 'display') {
        if ($argc !== 4 || !in_array($argv[3], ['full','bounded'], true)) throw new RuntimeException('Invalid display request');
        $text = pg_ls_read_file($argv[2], 4194304); $display = $argv[3];
    } elseif ($mode === 'redact' && $argc === 2) {
        $text = stream_get_contents(STDIN, 4194305); $display = 'full';
        if ($text === false || strlen($text) > 4194304) throw new RuntimeException('Response exceeds bound');
    } else throw new RuntimeException('Invalid output mode');
    pg_ls_render($text, $display);
} catch (Throwable $e) {
    fwrite(STDERR, "Provider output could not be verified or safely displayed; response suppressed.\n");
    exit(2);
}
