<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;

/** argv split into positionals and known options. Unknown options are an error, never ignored. */
final readonly class Input
{
    public const array FLAGS = ['json', 'dry-run', 'yes', 'force', 'wait', 'proxied', 'help', 'verbose', 'quiet', 'backups', 'disk', 'below'];

    public const array VALUES = ['name', 'type', 'ttl', 'zone', 'project', 'priority', 'comment', 'tag', 'timeout',
        // do firewalls / droplets / uptime
        'vpc', 'ssh-from', 'droplet', 'ports', 'region', 'size', 'image', 'ssh-keys', 'user-data', 'regions', 'email', 'threshold', 'period', 'value', 'window',
        // health
        'expect', 'contains', 'max-ms',
        // ploi
        'web-directory', 'project-type', 'user', 'file', 'command', 'processes', 'directory',
        // keys
        'provider', 'host', 'key-file', 'public-key', 'ssh-opt', 'config'];

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
            } elseif ($token === '-q') {
                $token = '--quiet';
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

    /**
     * A comma-separated option as a list (empty items dropped).
     *
     * @return list<string>
     */
    public function list(string $name): array
    {
        $value = $this->values[$name] ?? '';

        return array_values(array_filter(array_map(trim(...), explode(',', $value)), static fn (string $v): bool => $v !== ''));
    }

    /** @return list<int> */
    public function ints(string $name): array
    {
        return array_values(array_map(static function (string $v) use ($name): int {
            if (preg_match('/^\d{1,12}$/', $v) !== 1) {
                throw new ValidationException("--{$name} takes whole numbers separated by commas");
            }

            return (int) $v;
        }, $this->list($name)));
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
