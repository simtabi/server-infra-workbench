<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Cloudflare;

use Simtabi\ServerInfraWorkbench\Cloudflare\Data\Zone;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Item;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/**
 * Basic zone firewall: IP access rules (block / challenge / allow an IP, range, ASN or country) and a
 * read-only view of the WAF custom rules. Writing WAF rule expressions is left to the dashboard or
 * Terraform: a bad expression can block every visitor.
 */
final readonly class Firewall
{
    public const array MODES = ['block', 'challenge', 'js_challenge', 'managed_challenge', 'whitelist'];

    public const array TARGETS = ['ip', 'ip6', 'ip_range', 'asn', 'country'];

    private Endpoint $rules;

    public function __construct(private Transport $transport, private Zone $zone)
    {
        $this->rules = new Endpoint($transport, 'access rule', "/zones/{$zone->id}/firewall/access_rules/rules", new CloudflarePaginator, [
            'id' => 'id', 'mode' => 'mode', 'target' => 'configuration.target', 'value' => 'configuration.value', 'notes' => 'notes', 'scope' => 'scope.type',
        ], CloudflarePaginator::result(...), ['per_page' => 100]);
    }

    /** @return list<Item> */
    public function accessRules(): array
    {
        return $this->rules->list();
    }

    /**
     * Idempotent: the same target+value with the same mode is a no-op.
     *
     * @return PendingAction<Item>
     */
    public function addAccessRule(string $mode, string $target, string $value, string $notes = ''): PendingAction
    {
        $mode = $mode === 'allow' ? 'whitelist' : $mode;
        if (! in_array($mode, self::MODES, true)) {
            throw new ValidationException('mode must be one of block, challenge, js_challenge, managed_challenge, allow');
        }
        if (! in_array($target, self::TARGETS, true)) {
            throw new ValidationException('target must be one of '.implode(', ', self::TARGETS));
        }
        $value = match ($target) {
            'ip', 'ip6' => filter_var($value, FILTER_VALIDATE_IP) !== false ? $value : throw new ValidationException("\"{$value}\" is not an IP address"),
            'ip_range' => str_contains(Validate::cidr($value, 'ip range'), '/') ? $value : throw new ValidationException('an ip_range needs a prefix (/16, /24, /48 or /64)'),
            'asn' => preg_match('/^(AS)?\d{1,10}$/i', $value) === 1 ? strtoupper(str_starts_with(strtoupper($value), 'AS') ? $value : 'AS'.$value) : throw new ValidationException("\"{$value}\" is not an ASN"),
            default => preg_match('/^[A-Z]{2}$|^T1$/', $value) === 1 ? $value : throw new ValidationException("\"{$value}\" is not a two-letter country code"),
        };
        foreach ($this->accessRules() as $rule) {
            if ($rule->string('target') === $target && $rule->string('value') === $value && $rule->string('mode') === $mode) {
                return $this->rules->noop('add access rule', "{$mode} {$target} {$value} (exists)", $rule);
            }
        }
        $body = ['mode' => $mode, 'configuration' => ['target' => $target, 'value' => $value], 'notes' => Validate::label($notes === '' ? 'workbench' : $notes, 'notes', 500)];

        return $this->rules->create($body, "{$mode} {$target} {$value} on {$this->zone->name}",
            $mode === 'whitelist' ? 'allowed traffic skips WAF and security-level checks' : 'applies at the edge within seconds', destructive: $mode === 'whitelist' && $target === 'country');
    }

    /** @return PendingAction<bool> */
    public function deleteAccessRule(string $id): PendingAction
    {
        return $this->rules->delete(Validate::segment($id, 'rule id', 64));
    }

    /**
     * The zone's WAF custom rules (http_request_firewall_custom phase); empty when none were ever made.
     *
     * @return list<Item>
     */
    public function customRules(): array
    {
        try {
            $set = CloudflarePaginator::result($this->transport->get("/zones/{$this->zone->id}/rulesets/phases/http_request_firewall_custom/entrypoint")->json);
        } catch (\Simtabi\ServerInfraWorkbench\Exception\NotFoundException) {
            return [];
        }

        return array_map(static fn (array $r): Item => Item::of($r, ['id' => 'id', 'action' => 'action', 'expression' => 'expression', 'description' => 'description', 'enabled' => 'enabled']),
            Data::objects($set, 'rules'));
    }
}
