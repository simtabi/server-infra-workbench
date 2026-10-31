<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Snapshot;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Snapshots
{
    public function __construct(private Transport $transport) {}

    /** @return list<Snapshot> */
    public function list(string $resourceType = 'droplet'): array
    {
        $query = ['per_page' => 200, 'resource_type' => in_array($resourceType, ['droplet', 'volume'], true) ? $resourceType : 'droplet'];
        $out = [];
        foreach ($this->transport->paginate('/v2/snapshots', $query, new DigitalOceanPaginator('snapshots')) as $row) {
            $out[] = Snapshot::fromArray($row);
        }

        return $out;
    }

    public function find(string $id): Snapshot
    {
        return Snapshot::fromArray(Data::map($this->transport->get('/v2/snapshots/'.Validate::token($id, 'snapshot id'))->json, 'snapshot'));
    }

    /**
     * Destructive: the image is gone for good.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $id): PendingAction
    {
        $path = '/v2/snapshots/'.Validate::token($id, 'snapshot id');

        return $this->transport->pending(
            'delete snapshot',
            $id,
            'DELETE',
            $path,
            [],
            fn (): bool => $this->transport->send('DELETE', $path)->status === 204,
            destructive: true,
        );
    }
}
