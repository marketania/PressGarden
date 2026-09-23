<?php
/** Also run with PHP 7.4 and no terminal. Display must be optional. */
require __DIR__.'/../lib/progress.php';
putenv('PG_PROGRESS_ACTIVE=0');
ob_start();
$p = new PressGardenProgress('PHP');
$p->advance(0, true); $p->advance(15); $p->finish(15, 0); unset($p);
if (ob_get_clean() !== '') exit(1);
// A caller without a controlling terminal must retain its own stdout/stderr.
if (!function_exists('stream_isatty') || !@stream_isatty(STDIN)) {
    putenv('PG_PROGRESS_ACTIVE=1'); putenv('PG_PROGRESS_TOTAL=20');
    $p = new PressGardenProgress('JavaScript'); $p->advance(5, true); $p->finish(5, 1);
}
echo "Optional progress helper: PASS\n";
