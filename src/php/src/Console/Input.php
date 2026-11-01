<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;

/** argv split into positionals and known options. Unknown options are an error, never ignored. */
final readonly class Input
{
    public const array FLAGS = ['json', 'dry-run', 'yes', 'force', 'wait', 'proxied', 'help', 'verbose', 'quiet', 'backups', 'disk', 'below',
        'everything', 'draft', 'prerelease', 'write'];

    public const array VALUES = ['name', 'type', 'ttl', 'zone', 'project', 'priority', 'comment', 'tag', 'timeout',
        // do firewalls / droplets / uptime
        'vpc', 'ssh-from', 'droplet', 'ports', 'region', 'size', 'image', 'ssh-keys', 'user-data', 'regions', 'email', 'threshold', 'period', 'value', 'window',
        // health
        'expect', 'contains', 'max-ms',
        // ploi
        'web-directory', 'project-type', 'user', 'file', 'command', 'processes', 'directory',
        // keys
        'provider', 'host', 'key-file', 'public-key', 'ssh-opt', 'config',
        // do volumes / vpcs / spaces keys / reserved ips
        'size-gb', 'filesystem', 'ip-range', 'description', 'bucket', 'permission', 'out', 'ip',
        // cloudflare
        'hostnames', 'validity', 'files', 'target',
        // gcp
        'location', 'storage-class', 'retention-days', 'prefix', 'limit', 'disk-gb', 'network', 'allow', 'source-ranges', 'target-tags',
        // ploi
        'frequency', 'site', 'domain',
        // github
        'repo', 'org', 'workflow', 'branch', 'status', 'ref', 'inputs', 'env', 'value-file', 'title', 'notes-file'];

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
                // A repeated option used to keep only the last value, so `--droplet A --droplet B`
                // silently targeted B alone. Lists are comma-separated; a repeat is a usage error.
                if (array_key_exists($key, $values)) {
                    throw new ValidationException("--{$key} given twice; pass a comma-separated list instead (--{$key} a,b)");
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

    /** A value option that must be present. */
    public function required(string $name, string $hint = ''): string
    {
        $value = $this->values[$name] ?? null;

        return $value === null || $value === '' ? throw new ValidationException("--{$name} is required".($hint === '' ? '' : " ({$hint})")) : $value;
    }

    /**
     * Positionals from $index on (e.g. a list of ids).
     *
     * @return list<string>
     */
    public function rest(int $index, string $name): array
    {
        $rest = array_values(array_slice($this->args, $index));

        return $rest === [] ? throw new ValidationException("missing <{$name}>") : $rest;
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
