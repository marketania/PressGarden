<?php
/** Terminal-only, throttled activity counts. Does not change scan decisions. */
final class PressGardenProgress {
    private $tty = null;
    private $total = 0;
    private $width = 79;
    private $last = 0.0;
    private $started = 0.0;
    private $label;
    private $completeList = true;

    public function __construct($label) {
        $this->label = $label;
        if (getenv('PG_PROGRESS_ACTIVE') !== '1' || !function_exists('stream_isatty')) return;
        // Only a controlling terminal is ever opened. Do not accept arbitrary
        // output paths or descriptors from configuration or analyzed content.
        $tty = @fopen('/dev/tty', 'wb');
        if ($tty === false) return;
        if (!@stream_isatty($tty)) { @fclose($tty); return; }
        $this->tty = $tty;
        $count = getenv('PG_PROGRESS_TOTAL');
        if (is_string($count) && preg_match('/^[0-9]{1,9}$/D', $count)) $this->total = (int)$count;
        $width = getenv('PG_PROGRESS_WIDTH');
        if (is_string($width) && preg_match('/^[0-9]{2,3}$/D', $width)
            && (int)$width >= 19 && (int)$width <= 239) $this->width = (int)$width;
        $this->completeList = getenv('PG_PROGRESS_LIST_COMPLETE') !== '0';
        $this->started = microtime(true);
        $this->advance(0, true);
    }

    public function advance($processed, $force = false) {
        if (!is_resource($this->tty)) return;
        $now = microtime(true);
        if (!$force && $now - $this->last < 2.0) return;
        $this->last = $now;
        // The denominator is eligible files, not bytes or expected duration.
        // Reserve 100% for an explicitly successful end; errors are separate.
        $count = number_format($processed, 0, '.', ',');
        if ($this->completeList && $this->total > 0 && $processed <= $this->total) {
            $percent = min(99, (int)floor($processed * 100.0 / $this->total));
            $text = $this->label.': '.$percent.'% | '.$count.'/'.number_format($this->total, 0, '.', ',').' files processed';
        } else $text = $this->label.': '.$count.' files processed';
        $elapsed = max(0, (int)($now - $this->started));
        $this->write($text.' | '.intdiv($elapsed, 60).'m '.($elapsed % 60).'s');
    }

    public function finish($processed, $errors) {
        if (!is_resource($this->tty)) return;
        if ($errors > 0) $text = $this->label.': INCOMPLETE | '.$processed.' files processed | '.$errors.' failed';
        elseif (!$this->completeList) $text = $this->label.': INCOMPLETE SCOPE | '.$processed.' files processed';
        elseif ($this->total > 0 && $processed === $this->total) $text = $this->label.': 100% | '.$processed.'/'.$this->total.' files processed';
        else $text = $this->label.': '.$processed.' files processed';
        $this->write($text);
        // End the transient line before ordinary results resume. This is
        // activity, never a CLEAN/VERIFIED verdict and never stored evidence.
        if (is_resource($this->tty)) @fwrite($this->tty, "\n");
        $this->close();
    }

    private function write($text) {
        $text = preg_replace('/[^\x20-\x7e]/', '?', '    '.$text);
        $line = "\r".str_pad(substr($text, 0, $this->width), $this->width);
        if (@fwrite($this->tty, $line) !== strlen($line)) { $this->close(); return; }
        @fflush($this->tty);
    }

    private function close() {
        if (is_resource($this->tty)) @fclose($this->tty);
        $this->tty = null;
    }

    public function __destruct() {
        if (is_resource($this->tty)) {
            @fwrite($this->tty, "\r".str_repeat(' ', $this->width)."\r");
            $this->close();
        }
    }
}
