<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\UptimeAlert;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\UptimeCheck;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

/** DigitalOcean uptime checks (probes from several regions) and their alerts. */
final readonly class Uptime
{
    public const array TYPES = ['https', 'http', 'ping'];

    public const array REGIONS = ['us_east', 'us_west', 'eu_west', 'se_asia'];

    public const array ALERT_TYPES = ['down', 'down_global', 'latency', 'ssl_expiry'];

    public function __construct(private Transport $transport) {}

    /** @return list<UptimeCheck> */
    public function checks(): array
    {
        $out = [];
        foreach ($this->transport->paginate('/v2/uptime/checks', ['per_page' => 200], new DigitalOceanPaginator('checks')) as $row) {
            $out[] = UptimeCheck::fromArray($row);
        }

        return $out;
    }

    /** @return array<string, mixed> e.g. ['regions' => ['us_east' => ['status' => 'UP', ...]], 'previous_outage' => ...] */
    public function state(string $checkId): array
    {
        return Data::map($this->transport->get('/v2/uptime/checks/'.Validate::token($checkId, 'check id').'/state')->json, 'state');
    }

    /**
     * Creates a check, or does nothing when one with the same name and target exists.
     *
     * @param list<string> $regions
     * @return PendingAction<UptimeCheck>
     */
    public function createCheck(string $name, string $target, string $type = 'https', array $regions = self::REGIONS): PendingAction
    {
        $name = Validate::label($name, 'check name');
        if (! in_array($type, self::TYPES, true)) {
            throw new ValidationException('check type must be one of: '.implode(', ', self::TYPES));
        }
        $target = self::target($target, $type);
        foreach ($regions as $region) {
            if (! in_array($region, self::REGIONS, true)) {
                throw new ValidationException(sprintf('unknown uptime region "%s"; use: %s', $region, implode(', ', self::REGIONS)));
            }
        }
        foreach ($this->checks() as $check) {
            if ($check->name === $name && $check->target === $target) {
                return $this->transport->pending('create uptime check', "\"{$name}\" -> {$target}", 'NONE', '/v2/uptime/checks/'.$check->id, [], static fn (): UptimeCheck => $check);
            }
        }
        $body = ['name' => $name, 'type' => $type, 'target' => $target, 'regions' => array_values($regions), 'enabled' => true];

        return $this->transport->pending('create uptime check', "\"{$name}\" -> {$target}", 'POST', '/v2/uptime/checks', $body,
            fn (): UptimeCheck => UptimeCheck::fromArray(Data::map($this->transport->send('POST', '/v2/uptime/checks', [], $body)->json, 'check')),
            note: 'probes run from DigitalOcean regions; first results within minutes');
    }

    /** @return PendingAction<bool> */
    public function deleteCheck(string $checkId): PendingAction
    {
        $path = '/v2/uptime/checks/'.Validate::token($checkId, 'check id');

        return $this->transport->pending('delete uptime check', $checkId, 'DELETE', $path, [], fn (): bool => $this->transport->send('DELETE', $path)->status === 204, destructive: true);
    }

    /** @return list<UptimeAlert> */
    public function alerts(string $checkId): array
    {
        $out = [];
        $path = '/v2/uptime/checks/'.Validate::token($checkId, 'check id').'/alerts';
        foreach ($this->transport->paginate($path, ['per_page' => 200], new DigitalOceanPaginator('alerts')) as $row) {
            $out[] = UptimeAlert::fromArray($row);
        }

        return $out;
    }

    /**
     * @param list<string> $emails  must be verified on the DigitalOcean team
     * @return PendingAction<UptimeAlert>
     */
    public function createAlert(string $checkId, string $type, array $emails, int $threshold = 0, string $period = '2m', ?string $name = null): PendingAction
    {
        if (! in_array($type, self::ALERT_TYPES, true)) {
            throw new ValidationException('alert type must be one of: '.implode(', ', self::ALERT_TYPES));
        }
        if (! in_array($period, ['2m', '3m', '5m', '10m', '15m', '30m', '1h'], true)) {
            throw new ValidationException('alert period must be one of 2m 3m 5m 10m 15m 30m 1h');
        }
        if ($emails === []) {
            throw new ValidationException('an alert needs at least one --email');
        }
        foreach ($emails as $email) {
            if (filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
                throw new ValidationException(sprintf('"%s" is not an email address', $email));
            }
        }
        $threshold = match ($type) {
            'latency' => Validate::range($threshold > 0 ? $threshold : 2000, 1, 60000, 'latency threshold (ms)'),
            'ssl_expiry' => Validate::range($threshold > 0 ? $threshold : 14, 1, 365, 'ssl expiry threshold (days)'),
            default => 0,
        };
        $path = '/v2/uptime/checks/'.Validate::token($checkId, 'check id').'/alerts';
        $body = [
            'name' => Validate::label($name ?? "{$type} alert", 'alert name'),
            'type' => $type,
            'threshold' => $threshold,
            'comparison' => $type === 'ssl_expiry' ? 'less_than' : 'greater_than',
            'notifications' => ['email' => array_values($emails), 'slack' => []],
            'period' => $period,
        ];

        return $this->transport->pending('create uptime alert', "{$type} on check {$checkId}", 'POST', $path, $body,
            fn (): UptimeAlert => UptimeAlert::fromArray(Data::map($this->transport->send('POST', $path, [], $body)->json, 'alert')));
    }

    private static function target(string $target, string $type): string
    {
        if ($type === 'ping') {
            return filter_var($target, FILTER_VALIDATE_IP) !== false ? $target : Validate::domain($target, 'ping target');
        }
        $parts = parse_url($target);
        if (! is_array($parts) || ($parts['scheme'] ?? '') !== $type || ! isset($parts['host'])) {
            throw new ValidationException(sprintf('target must be a %s:// URL, got "%s"', $type, $target));
        }

        return $target;
    }
}
