<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Gcp\Data\Instance;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Instances
{
    public function __construct(private Transport $transport, private string $project) {}

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
        $path = sprintf('/projects/%s/zones/%s/instances/%s', $this->project, Validate::gcpName($zone, 'zone'), Validate::gcpName($name, 'instance'));

        return Instance::fromArray(Data::map(['i' => $this->transport->get($path)->json], 'i'));
    }
}
