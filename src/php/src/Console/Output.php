<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

use Simtabi\ServerInfraWorkbench\Security\Redactor;

/** Everything printed goes through the redactor, as a last line of defence. */
final class Output
{
    /** @var resource */
    private $out;

    /** @var resource */
    private $err;

    /**
     * @param resource|null $out
     * @param resource|null $err
     */
    public function __construct($out = null, $err = null, private readonly Redactor $redactor = new Redactor)
    {
        $this->out = $out ?? STDOUT;
        $this->err = $err ?? STDERR;
    }

    public function line(string $text = ''): void
    {
        fwrite($this->out, $this->redactor->redact($text)."\n");
    }

    public function error(string $text): void
    {
        fwrite($this->err, $this->redactor->redact($text)."\n");
    }

    public function json(mixed $data): void
    {
        $this->line(json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE));
    }

    /**
     * @param list<array<string, mixed>> $rows
     * @param array<string, string>      $columns key => heading
     */
    public function table(array $rows, array $columns): void
    {
        if ($rows === []) {
            $this->line('(none)');

            return;
        }
        $cells = [array_values($columns)];
        foreach ($rows as $row) {
            $cells[] = array_map(static fn (string $key): string => self::cell($row[$key] ?? null), array_keys($columns));
        }
        $widths = [];
        foreach ($cells as $line) {
            foreach ($line as $i => $cell) {
                $widths[$i] = max($widths[$i] ?? 0, mb_strwidth($cell));
            }
        }
        foreach ($cells as $line) {
            $padded = [];
            foreach ($line as $i => $cell) {
                $padded[] = $cell.str_repeat(' ', $widths[$i] - mb_strwidth($cell));
            }
            $this->line(rtrim(implode('  ', $padded)));
        }
    }

    private static function cell(mixed $value): string
    {
        return match (true) {
            $value === null => '-',
            is_bool($value) => $value ? 'yes' : 'no',
            is_array($value) => implode(',', array_map(static fn (mixed $v): string => is_scalar($v) ? (string) $v : '…', $value)),
            $value instanceof \BackedEnum => (string) $value->value,
            is_scalar($value) => (string) $value,
            default => '…',
        };
    }
}
