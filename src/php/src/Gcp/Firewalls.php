<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Gcp\Data\Firewall;
use Simtabi\ServerInfraWorkbench\Gcp\Data\Operation;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/** VPC firewall rules (ingress allow rules). Opening a non-web port to the world is destructive. */
final readonly class Firewalls
{
    /** Ports that are normal to expose to 0.0.0.0/0. */
    public const array PUBLIC_PORTS = ['80', '443'];

    public function __construct(private Transport $transport, private string $project, private Operations $operations) {}

    /** @return list<Firewall> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate("/projects/{$this->project}/global/firewalls", ['maxResults' => 500], new GcpPaginator) as $row) {
            $out[] = Firewall::fromArray($row);
        }

        return $out;
    }

    /**
     * An ingress allow rule, e.g. allow(['tcp:22'], ['198.51.100.0/24'], ['web']). Idempotent by name.
     *
     * @param list<string> $allow        protocol[:ports] (tcp:22, tcp:8000-8100, udp:51820, icmp)
     * @param list<string> $sourceRanges CIDRs
     * @param list<string> $targetTags   network tags; empty = every instance in the network
     * @return PendingAction<RunningOperation>
     */
    public function create(string $name, array $allow, array $sourceRanges, array $targetTags = [], string $network = 'default', int $priority = 1000, string $description = ''): PendingAction
    {
        $name = Validate::gcpName($name, 'firewall rule');
        if ($allow === [] || $sourceRanges === []) {
            throw new ValidationException('a rule needs --allow (e.g. tcp:22) and --source-ranges (e.g. 198.51.100.7/32)');
        }
        $allowed = [];
        $ports = [];
        foreach ($allow as $spec) {
            if (preg_match('/^(tcp|udp|icmp|sctp|esp|ah)(?::(\d{1,5}(?:-\d{1,5})?(?:,\d{1,5}(?:-\d{1,5})?)*))?$/', $spec, $m) !== 1) {
                throw new ValidationException(sprintf('"%s" is not protocol[:ports] (tcp:22, udp:51820, icmp)', $spec));
            }
            $list = isset($m[2]) ? explode(',', $m[2]) : [];
            $allowed[] = ['IPProtocol' => $m[1]] + ($list === [] ? [] : ['ports' => $list]);
            $ports = [...$ports, ...($list === [] ? ['all '.$m[1]] : $list)];
        }
        foreach ($sourceRanges as $range) {
            Validate::cidr($range, 'source range');
        }
        $world = array_intersect($sourceRanges, ['0.0.0.0/0', '::/0']) !== [];
        $risky = $world && array_diff($ports, self::PUBLIC_PORTS) !== [];
        $path = "/projects/{$this->project}/global/firewalls";
        foreach ($this->list() as $rule) {
            if ($rule->name === $name) {
                return $this->transport->pending('create firewall rule', "{$name} (exists)", 'NONE', $path, [], fn (): RunningOperation => $this->operations->track(
                    new Operation('exists', 'insert', 'DONE', null, $name, null),
                ));
            }
        }
        $body = array_filter([
            'name' => $name, 'network' => 'global/networks/'.Validate::gcpName($network, 'network'), 'direction' => 'INGRESS',
            'priority' => Validate::range($priority, 0, 65535, 'priority'), 'allowed' => $allowed, 'sourceRanges' => $sourceRanges,
            'targetTags' => array_map(static fn (string $t): string => Validate::gcpName($t, 'target tag'), $targetTags),
            'description' => $description === '' ? 'managed by workbench' : Validate::label($description, 'description', 2048),
        ], static fn (mixed $v): bool => $v !== []);

        return $this->transport->pending('create firewall rule', sprintf('%s: allow %s from %s%s', $name, implode(' ', $allow), implode(' ', $sourceRanges), $targetTags === [] ? ' to every instance' : ' to tags '.implode(',', $targetTags)),
            'POST', $path, $body, fn (): RunningOperation => $this->operations->track(Operation::fromArray(Data::map(['op' => $this->transport->send('POST', $path, [], $body)->json], 'op'))),
            $risky, $risky ? 'opens a non-web port to the whole internet; restrict --source-ranges to your own IPs' : null);
    }

    /**
     * Destructive: traffic the rule allowed is dropped at once.
     *
     * @return PendingAction<RunningOperation>
     */
    public function delete(string $name): PendingAction
    {
        $path = "/projects/{$this->project}/global/firewalls/".Validate::gcpName($name, 'firewall rule');

        return $this->transport->pending('delete firewall rule', $name, 'DELETE', $path, [], fn (): RunningOperation => $this->operations->track(
            Operation::fromArray(Data::map(['op' => $this->transport->send('DELETE', $path)->json], 'op')),
        ), true, 'traffic it allowed (maybe your SSH session) is dropped at once');
    }
}
