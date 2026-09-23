<?php
/** Read-only configuration advice. Reads names only; never sources shell code. */
function pg_config_names($path, $optional) {
    if (!file_exists($path) && !is_link($path) && $optional) return [];
    if (!is_file($path) || !is_readable($path) || filesize($path) > 1048576) throw new RuntimeException('configuration input is unreadable or exceeds 1 MiB');
    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if ($lines === false) throw new RuntimeException('cannot read configuration input');
    $keys = [];
    foreach ($lines as $line) {
        if (preg_match('/^\s*(?:export\s+)?(PRESSGARDEN_[A-Za-z0-9_]+)\s*=/', $line, $m)) $keys[$m[1]] = true;
    }
    return $keys;
}
try {
    if ($argc < 3 || $argc > 4 || ($argc === 4 && $argv[3] !== '--brief')) throw new RuntimeException('invalid configuration comparison arguments');
    $available = pg_config_names($argv[1], false);
    $configured = pg_config_names($argv[2], true);
    $new = array_keys(array_diff_key($available, $configured));
    sort($new, SORT_STRING);
    if ($argc === 4) {
        if ($new) printf("\nℹ %d template option(s) are not explicitly set in your saved config. Run ./pressgarden config-new to review names.\n", count($new));
    } else {
        echo "PressGarden configuration options\n\n";
        if (!$new) echo "No additional template options. Your saved config was not changed.\n";
        else {
            printf("%d template option(s) are not explicitly set in your saved config:\n", count($new));
            foreach ($new as $key) echo '  '.$key."\n";
            echo "\nThese are optional overrides, not missing required settings.\n";
            echo "Review config/config.example and add only the settings you need.\n";
            echo "Do not replace your private config with the template.\n";
        }
        echo "\nValues are never displayed. This comparison reads assignment names; it does not evaluate shell expressions, sourced files, or environment overrides.\n";
    }
} catch (Throwable $e) { fwrite(STDERR, 'Configuration comparison failed: '.$e->getMessage().".\n"); exit(2); }
