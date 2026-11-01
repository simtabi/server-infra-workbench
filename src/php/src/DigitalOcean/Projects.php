<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/** Projects group resources in the dashboard (and for billing reports). Moving a resource changes nothing else. */
final readonly class Projects
{
    private Endpoint $api;

    public function __construct(Transport $transport)
    {
        $this->api = new Endpoint($transport, 'project', '/v2/projects', new DigitalOceanPaginator('projects'), [
            'id' => 'id', 'name' => 'name', 'purpose' => 'purpose', 'environment' => 'environment', 'default' => 'is_default',
        ], 'project', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /** @return list<Item> */
    public function resources(string $projectId): array
    {
        return (new Endpoint($this->api->transport(), 'project resource', $this->api->path(Validate::token($projectId, 'project id'), 'resources'),
            new DigitalOceanPaginator('resources'), ['urn' => 'urn', 'status' => 'status', 'assignedAt' => 'assigned_at'], null, ['per_page' => 200]))->list();
    }

    /**
     * Move resources into a project. URNs look like do:droplet:123, do:volume:<uuid>, do:domain:example.com.
     *
     * @param list<string> $urns
     * @return PendingAction<array<mixed>>
     */
    public function assign(string $projectId, array $urns): PendingAction
    {
        if ($urns === []) {
            throw new ValidationException('name at least one resource URN (e.g. do:droplet:123)');
        }
        foreach ($urns as $urn) {
            if (preg_match('/^do:[a-z_]+:[A-Za-z0-9._-]{1,128}$/', $urn) !== 1) {
                throw new ValidationException(sprintf('"%s" is not a DigitalOcean URN (do:<type>:<id>)', substr($urn, 0, 80)));
            }
        }
        $path = $this->api->path(Validate::token($projectId, 'project id'), 'resources');

        return $this->api->call('assign to project', implode(', ', $urns)." -> {$projectId}", 'POST', $path, ['resources' => $urns], note: 'a resource is in exactly one project; this moves it');
    }
}
