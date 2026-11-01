<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Cloudflare;

use Simtabi\ServerInfraWorkbench\Cloudflare\Data\Zone;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;

/**
 * The handful of zone settings that matter for a server behind Cloudflare. Allowlisted on purpose:
 * each one has a known value set, so a typo cannot quietly flip something else.
 */
final readonly class ZoneSettings
{
    /** setting => allowed values */
    public const array SETTINGS = [
        'ssl' => ['off', 'flexible', 'full', 'strict'],
        'always_use_https' => ['on', 'off'],
        'automatic_https_rewrites' => ['on', 'off'],
        'min_tls_version' => ['1.0', '1.1', '1.2', '1.3'],
        'tls_1_3' => ['on', 'off', 'zrt'],
        'security_level' => ['essentially_off', 'low', 'medium', 'high', 'under_attack'],
    ];

    public function __construct(private Transport $transport, private Zone $zone) {}

    /** @return array<string, string> setting => current value */
    public function all(): array
    {
        $out = [];
        foreach (array_keys(self::SETTINGS) as $name) {
            $out[$name] = $this->get($name);
        }

        return $out;
    }

    public function get(string $name): string
    {
        $result = CloudflarePaginator::result($this->transport->get($this->path(self::name($name)))->json);
        $value = $result['value'] ?? '';

        return is_scalar($value) ? (string) $value : (string) json_encode($value);
    }

    /**
     * A no-op when it already has the value. Lowering security (ssl off/flexible, an old TLS minimum,
     * security_level essentially_off, always_use_https off) is destructive and needs --force.
     *
     * @return PendingAction<string>
     */
    public function set(string $name, string $value): PendingAction
    {
        $name = self::name($name);
        if (! in_array($value, self::SETTINGS[$name], true)) {
            throw new ValidationException(sprintf('%s must be one of %s', $name, implode(', ', self::SETTINGS[$name])));
        }
        $current = $this->get($name);
        $target = "{$name} on {$this->zone->name}: {$current} -> {$value}";
        $path = $this->path($name);
        if ($current === $value) {
            return $this->transport->pending("set {$name}", "{$name} on {$this->zone->name} (already {$value})", 'NONE', $path, [], static fn (): string => $value);
        }
        $weaker = match ($name) {
            'ssl' => in_array($value, ['off', 'flexible'], true),
            'min_tls_version' => version_compare($value, '1.2', '<'),
            'security_level' => $value === 'essentially_off',
            'always_use_https', 'automatic_https_rewrites' => $value === 'off',
            default => false,
        };
        $note = match (true) {
            $name === 'ssl' && $value === 'flexible' => 'flexible = plain HTTP between Cloudflare and the origin; use full (strict) with an origin certificate (siwo cf origin-certs create)',
            $name === 'ssl' && $value === 'strict' => 'the origin must present a valid or Cloudflare Origin CA certificate, or visitors get 526 errors',
            $weaker => 'lowers the security of the zone',
            default => null,
        };

        return $this->transport->pending("set {$name}", $target, 'PATCH', $path, ['value' => $value],
            fn (): string => Data::string(CloudflarePaginator::result($this->transport->send('PATCH', $path, [], ['value' => $value])->json), 'value'),
            $weaker, $note);
    }

    private function path(string $name): string
    {
        return "/zones/{$this->zone->id}/settings/{$name}";
    }

    private static function name(string $name): string
    {
        $name = str_replace('-', '_', $name);

        return array_key_exists($name, self::SETTINGS) ? $name
            : throw new ValidationException(sprintf('setting "%s" is not managed here; one of %s', $name, implode(', ', array_keys(self::SETTINGS))));
    }
}
