<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

use Simtabi\ServerInfraWorkbench\Security\Redactor;
use Simtabi\ServerInfraWorkbench\Support\Env;

/**
 * Spinner, bar, ETA and elapsed time on stderr, so stdout (tables, --json) stays parseable.
 * Same switches as the shell tools (src/shell/lib/progress.sh):
 *   SIW_PROGRESS=auto|tty|plain|off (auto: animate on a terminal, plain lines otherwise), SIW_QUIET=1, NO_COLOR.
 */
final class Progress
{
    public const string TTY = 'tty';

    public const string PLAIN = 'plain';

    public const string OFF = 'off';

    private const string FRAMES = '|/-\\';

    private int $frame = 0;

    private int $lastPlainMinute = -1;

    /** @var resource */
    private $stream;

    /** @param resource $stream */
    public function __construct($stream, private readonly string $mode, private readonly bool $color = false, private readonly Redactor $redactor = new Redactor)
    {
        $this->stream = $stream;
    }

    /**
     * @param resource|null              $stream default STDERR
     * @param array<string, string>|null $env    default getenv()
     */
    public static function detect($stream = null, ?array $env = null, ?bool $isTty = null): self
    {
        $stream ??= STDERR;
        $env = Env::withFallbacks($env ?? getenv());
        $tty = $isTty ?? stream_isatty($stream);
        $mode = match (true) {
            ($env['SIW_QUIET'] ?? '') === '1' => self::OFF,
            in_array($env['SIW_PROGRESS'] ?? '', [self::TTY, self::PLAIN, self::OFF], true) => $env['SIW_PROGRESS'],
            $tty && ($env['TERM'] ?? 'dumb') !== 'dumb' => self::TTY,
            default => self::PLAIN,
        };

        return new self($stream, $mode, $mode === self::TTY && ($env['NO_COLOR'] ?? '') === '');
    }

    public static function off(): self
    {
        return new self(STDERR, self::OFF);
    }

    public function mode(): string
    {
        return $this->mode;
    }

    /** m:ss, or h:mm:ss from an hour */
    public static function duration(int $seconds): string
    {
        $seconds = max(0, $seconds);

        return $seconds >= 3600
            ? sprintf('%d:%02d:%02d', intdiv($seconds, 3600), intdiv($seconds % 3600, 60), $seconds % 60)
            : sprintf('%d:%02d', intdiv($seconds, 60), $seconds % 60);
    }

    /** Remaining seconds at the average rate so far; null before the first item or after the last. */
    public static function eta(int $elapsed, int $done, int $total): ?int
    {
        return $done > 0 && $done < $total ? intdiv($elapsed * ($total - $done), $done) : null;
    }

    public function bar(int $done, int $total, int $elapsed, string $label = ''): void
    {
        if ($this->mode === self::OFF || $total <= 0) {
            return;
        }
        $done = min(max(0, $done), $total);
        $pct = intdiv($done * 100, $total);
        $eta = self::eta($elapsed, $done, $total);
        $tail = sprintf('%3d%% %d/%d %s  %s%s', $pct, $done, $total, $label, self::duration($elapsed), $eta === null ? '' : ' eta '.self::duration($eta));
        if ($this->mode === self::TTY) {
            $fill = intdiv($done * 24, $total);
            $this->write("\r  [".str_repeat('#', $fill).str_repeat('-', 24 - $fill).'] '.$tail."\033[K".($done === $total ? "\n" : ''));

            return;
        }
        $this->write('  '.$tail."\n");
    }

    /** One poll of a long wait: a spinner on a terminal, a plain line at the start and once a minute otherwise. */
    public function waiting(string $what, int $waited, int $timeout): void
    {
        if ($this->mode === self::TTY) {
            $this->write(sprintf("\r  %s %s  %s / %s \033[K", self::FRAMES[$this->frame++ % 4], $what, self::duration($waited), self::duration($timeout)));
        } elseif ($this->mode === self::PLAIN && intdiv($waited, 60) !== $this->lastPlainMinute) {
            $this->lastPlainMinute = intdiv($waited, 60);
            $this->write(sprintf("  ..    waiting: %s  %s (up to %s)\n", $what, self::duration($waited), self::duration($timeout)));
        }
    }

    public function finished(string $what, int $seconds, bool $ok = true): void
    {
        if ($this->mode === self::OFF) {
            return;
        }
        $this->lastPlainMinute = -1;
        $word = $ok ? $this->paint('32', 'done') : $this->paint('31', 'FAIL');
        $this->write(($this->mode === self::TTY ? "\r\033[K" : '').sprintf("  %s  %s  (%s)\n", $word, $what, self::duration($seconds)));
    }

    private function paint(string $code, string $text): string
    {
        return $this->color ? "\033[{$code}m{$text}\033[0m" : $text;
    }

    private function write(string $text): void
    {
        fwrite($this->stream, $this->redactor->redact($text));
    }
}
