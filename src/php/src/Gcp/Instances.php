<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Gcp\Data\Instance;
use Simtabi\ServerInfraWorkbench\Gcp\Data\Operation;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

final readonly class Instances
{
    public function __construct(private Transport $transport, private string $project, private Operations $operations) {}

    /**
     * All zones (aggregated list), or one zone.
     *
     * @return list<Instance>
     */
    public function list(?string $zone = null): array
    {
        [$path, $paginator] = $zone === null
            ? ["/projects/{$this->project}/aggregated/instances", new GcpPaginator('instances')]
            : ["/projects/{$this->project}/zones/".Validate::gcpName($zone, 'zone').'/instances', new GcpPaginator];
        $query = $zone === null ? ['maxResults' => 500, 'returnPartialSuccess' => true] : ['maxResults' => 500];

        $out = [];
        foreach ($this->transport->paginate($path, $query, $paginator) as $row) {
            $out[] = Instance::fromArray($row);
        }

        return $out;
    }

    public function find(string $zone, string $name): Instance
    {
        return Instance::fromArray(Data::map(['i' => $this->transport->get($this->path($zone, $name))->json], 'i'));
    }

    /**
     * A minimal VM: one boot disk from a public image family, the default network with an ephemeral
     * external IP, OS Login on, the default service account with NO API scopes (least privilege), and
     * Shielded VM. Idempotent by name.
     *
     * @param list<string> $tags network tags (firewall targets)
     * @return PendingAction<RunningOperation>
     */
    public function create(string $zone, string $name, string $machineType = 'e2-small', string $image = 'projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64', int $diskGb = 20, array $tags = [], string $network = 'default'): PendingAction
    {
        $zone = Validate::gcpName($zone, 'zone');
        $name = Validate::gcpName($name, 'instance');
        Validate::gcpName($machineType, 'machine type');
        Validate::range($diskGb, 10, 65_536, 'disk (GB)');
        if (preg_match('#^projects/[a-z0-9-]+/global/images/(family/)?[a-z0-9-]+$#', $image) !== 1) {
            throw new ValidationException('image must look like projects/<project>/global/images/family/<family>');
        }
        $tags = array_map(static fn (string $t): string => Validate::gcpName($t, 'network tag'), $tags);
        $network = Validate::gcpName($network, 'network');
        $path = "/projects/{$this->project}/zones/{$zone}/instances";
        foreach ($this->list($zone) as $existing) {
            if ($existing->name === $name) {
                return $this->transport->pending('create instance', "{$zone}/{$name} (exists)", 'NONE', $path, [], fn (): RunningOperation => $this->operations->track(
                    new Operation('exists', 'insert', 'DONE', $zone, $existing->name, null),
                ));
            }
        }
        $body = [
            'name' => $name,
            'machineType' => "zones/{$zone}/machineTypes/{$machineType}",
            'disks' => [['boot' => true, 'autoDelete' => true, 'initializeParams' => ['sourceImage' => $image, 'diskSizeGb' => (string) $diskGb, 'diskType' => "zones/{$zone}/diskTypes/pd-balanced"]]],
            'networkInterfaces' => [['network' => "global/networks/{$network}", 'accessConfigs' => [['type' => 'ONE_TO_ONE_NAT', 'name' => 'External NAT']]]],
            'metadata' => ['items' => [['key' => 'enable-oslogin', 'value' => 'TRUE']]],
            'shieldedInstanceConfig' => ['enableSecureBoot' => true, 'enableVtpm' => true, 'enableIntegrityMonitoring' => true],
            'serviceAccounts' => [],
            'tags' => ['items' => $tags],
            'labels' => ['managed-by' => 'workbench'],
        ];

        return $this->operation('create instance', "{$zone}/{$name} ({$machineType}, {$diskGb} GB)", 'POST', $path, $body, false, 'billed per second while running; the boot disk bills until deleted');
    }

    /** @return PendingAction<RunningOperation> */
    public function start(string $zone, string $name): PendingAction
    {
        return $this->operation('start instance', "{$zone}/{$name}", 'POST', $this->path($zone, $name).'/start', [], false, null);
    }

    /** @return PendingAction<RunningOperation> */
    public function stop(string $zone, string $name): PendingAction
    {
        return $this->operation('stop instance', "{$zone}/{$name}", 'POST', $this->path($zone, $name).'/stop', [], false, 'downtime until started again; the ephemeral external IP is released');
    }

    /**
     * A hard reset (like pulling the power): unflushed writes can be lost.
     *
     * @return PendingAction<RunningOperation>
     */
    public function reset(string $zone, string $name): PendingAction
    {
        return $this->operation('reset instance', "{$zone}/{$name}", 'POST', $this->path($zone, $name).'/reset', [], true, 'hard reset: no clean shutdown');
    }

    /**
     * Destructive: the VM and its auto-delete disks are gone.
     *
     * @return PendingAction<RunningOperation>
     */
    public function delete(string $zone, string $name): PendingAction
    {
        return $this->operation('delete instance', "{$zone}/{$name}", 'DELETE', $this->path($zone, $name), [], true, 'boot disks marked autoDelete are destroyed; snapshot first if you may need them');
    }

    /**
     * @param array<string, mixed> $body
     * @return PendingAction<RunningOperation>
     */
    private function operation(string $action, string $target, string $method, string $path, array $body, bool $destructive, ?string $note): PendingAction
    {
        return $this->transport->pending($action, $target, $method, $path, $body, fn (): RunningOperation => $this->operations->track(
            Operation::fromArray(Data::map(['op' => $this->transport->send($method, $path, [], $method === 'DELETE' ? null : $body)->json], 'op')),
        ), $destructive, $note);
    }

    private function path(string $zone, string $name): string
    {
        return sprintf('/projects/%s/zones/%s/instances/%s', $this->project, Validate::gcpName($zone, 'zone'), Validate::gcpName($name, 'instance'));
    }
}
