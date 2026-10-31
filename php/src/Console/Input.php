<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;

/** argv split into positionals and known options. Unknown options are an error, never ignored. */
final readonly class Input
{
    public const array FLAGS = ['json', 'dry-run', 'yes', 'force', 'wait', 'proxied', 'help', 'verbose'];

    public const array VALUES = ['name', 'type', 'ttl', 'zone', 'project', 'priority', 'comment', 'tag', 'timeout'];

    /**
     * @param list<string>          $args
     * @param array<string, string> $values
     * @param array<string, true>   $flags
     */
    private function __construct(private array $args, private array $values, private array $flags) {}

    /** @param list<string> $argv */
    public static function parse(array $argv): self
    {
        $args = [];
        $values = [];
        $flags = [];
        for ($i = 0, $n = count($argv); $i < $n; $i++) {
            $token = $argv[$i];
            if ($token === '--') {
                array_push($args, ...array_slice($argv, $i + 1));

                break;
            }
            if ($token === '-h') {
                $token = '--help';
            } elseif ($token === '-n') {
                $token = '--dry-run';
            } elseif ($token === '-y') {
                $token = '--yes';
            }
            if (! str_starts_with($token, '--') || strlen($token) === 2) {
                $args[] = $token;

                continue;
            }
            [$key, $value] = array_pad(explode('=', substr($token, 2), 2), 2, null);
            if (in_array($key, self::FLAGS, true)) {
                if ($value !== null) {
                    throw new ValidationException("--{$key} does not take a value");
                }
                $flags[$key] = true;
            } elseif (in_array($key, self::VALUES, true)) {
                if ($value === null) {
                    $value = $argv[++$i] ?? throw new ValidationException("--{$key} needs a value");
                }
                $values[$key] = $value;
            } else {
                throw new ValidationException(sprintf('unknown option --%s (see: workbench help)', $key));
            }
        }

        return new self($args, $values, $flags);
    }

    public function arg(int $index, string $name): string
    {
        return $this->args[$index] ?? throw new ValidationException("missing <{$name}>");
    }

    public function optionalArg(int $index): ?string
    {
        return $this->args[$index] ?? null;
    }

    /** @return list<string> */
    public function args(): array
    {
        return $this->args;
    }

    public function count(): int
    {
        return count($this->args);
    }

    /** Fails on extra positionals, which usually mean a typo or a missing quote. */
    public function expectAtMost(int $count, string $usage): void
    {
        if (count($this->args) > $count) {
            throw new ValidationException(sprintf('unexpected argument "%s"; usage: workbench %s', $this->args[$count], $usage));
        }
    }

    public function flag(string $name): bool
    {
        return isset($this->flags[$name]);
    }

    public function value(string $name): ?string
    {
        return $this->values[$name] ?? null;
    }

    public function int(string $name, int $default): int
    {
        $value = $this->values[$name] ?? null;
        if ($value === null) {
            return $default;
        }
        if (preg_match('/^\d{1,9}$/', $value) !== 1) {
            throw new ValidationException("--{$name} must be a whole number");
        }

        return (int) $value;
    }
}
