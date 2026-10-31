<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Tests\Unit;

use PHPUnit\Framework\TestCase;
use Simtabi\VpsServerWorkbench\Console\Progress;
use Simtabi\VpsServerWorkbench\Console\ProgressSleeper;
use Simtabi\VpsServerWorkbench\Exception\TimeoutException;
use Simtabi\VpsServerWorkbench\Http\Waiter;
use Simtabi\VpsServerWorkbench\Tests\Fixtures\RecordingSleeper;

/** Console progress (spinner, bar, ETA) and its hook into Waiter. No real sleeping, no terminal needed. */
final class ProgressTest extends TestCase
{
    /** @var resource */
    private $stream;

    protected function setUp(): void
    {
        $stream = fopen('php://memory', 'w+');
        if ($stream === false) {
            throw new \RuntimeException('no memory stream');
        }
        $this->stream = $stream;
    }

    private function written(): string
    {
        rewind($this->stream);

        return (string) stream_get_contents($this->stream);
    }

    public function test_detect_honours_quiet_env_override_tty_and_no_color(): void
    {
        self::assertSame(Progress::OFF, Progress::detect($this->stream, ['VSW_QUIET' => '1', 'VSW_PROGRESS' => 'tty'], true)->mode());
        self::assertSame(Progress::PLAIN, Progress::detect($this->stream, ['VSW_PROGRESS' => 'plain', 'TERM' => 'xterm'], true)->mode());
        self::assertSame(Progress::TTY, Progress::detect($this->stream, ['TERM' => 'xterm'], true)->mode());
        self::assertSame(Progress::PLAIN, Progress::detect($this->stream, ['TERM' => 'dumb'], true)->mode());
        self::assertSame(Progress::PLAIN, Progress::detect($this->stream, ['TERM' => 'xterm'], false)->mode());
        Progress::detect($this->stream, ['TERM' => 'xterm', 'NO_COLOR' => '1'], true)->finished('x', 3);
        self::assertStringNotContainsString("\033[32m", $this->written());
    }

    public function test_duration_and_eta(): void
    {
        self::assertSame('0:07', Progress::duration(7));
        self::assertSame('2:05', Progress::duration(125));
        self::assertSame('1:00:01', Progress::duration(3601));
        self::assertSame(30, Progress::eta(10, 1, 4));
        self::assertNull(Progress::eta(10, 0, 4));
        self::assertNull(Progress::eta(10, 4, 4));
    }

    public function test_tty_bar_has_fill_percent_elapsed_and_eta(): void
    {
        (new Progress($this->stream, Progress::TTY))->bar(2, 4, 10, 'rows');
        self::assertStringContainsString('[############------------]  50% 2/4 rows  0:10 eta 0:10', $this->written());
    }

    public function test_plain_wait_prints_once_a_minute_then_done(): void
    {
        $p = new Progress($this->stream, Progress::PLAIN);
        foreach ([0, 10, 50, 60, 70] as $t) {
            $p->waiting('resize', $t, 600);
        }
        $p->finished('resize', 80);
        $out = $this->written();
        self::assertSame(2, substr_count($out, 'waiting: resize'));
        self::assertStringContainsString('done  resize  (1:20)', $out);
        self::assertStringNotContainsString("\r", $out);
    }

    public function test_off_writes_nothing(): void
    {
        $p = new Progress($this->stream, Progress::OFF);
        $p->bar(1, 2, 1);
        $p->waiting('x', 0, 10);
        $p->finished('x', 5);
        self::assertSame('', $this->written());
    }

    public function test_waiter_reports_polls_to_a_progress_sleeper_and_keeps_exact_fake_time(): void
    {
        $inner = new RecordingSleeper;
        $sleeper = new ProgressSleeper($inner, new Progress($this->stream, Progress::TTY, true));
        $n = 0;
        $result = Waiter::until($sleeper, static function () use (&$n): bool {
            $n++;

            return $n >= 3;
        }, static fn (bool $v): bool => $v, 60, 10, 'snapshot');
        self::assertTrue($result);
        self::assertSame([10_000, 10_000], $inner->sleeps);
        $out = $this->written();
        self::assertStringContainsString('snapshot  0:10 / 1:00', $out);
        self::assertStringContainsString("\033[32mdone\033[0m  snapshot  (0:20)", $out);
    }

    public function test_waiter_timeout_says_fail(): void
    {
        $sleeper = new ProgressSleeper(new RecordingSleeper, new Progress($this->stream, Progress::PLAIN));
        try {
            Waiter::until($sleeper, static fn (): bool => false, static fn (bool $v): bool => $v, 20, 10, 'resize');
            self::fail('expected a timeout');
        } catch (TimeoutException) {
            self::assertStringContainsString('FAIL  resize', $this->written());
        }
    }

    public function test_labels_are_redacted(): void
    {
        $token = 'dop_v1_'.str_repeat('a', 64);
        (new Progress($this->stream, Progress::PLAIN))->finished('call with '.$token, 1);
        self::assertStringNotContainsString($token, $this->written());
    }
}
