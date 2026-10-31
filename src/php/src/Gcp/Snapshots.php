<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Gcp\Data\Operation;
use Simtabi\VpsServerWorkbench\Gcp\Data\Snapshot;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Snapshots
{
    public function __construct(private Transport $transport, private string $project, private Operations $operations) {}

    /** @return list<Snapshot> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate("/projects/{$this->project}/global/snapshots", ['maxResults' => 500], new GcpPaginator) as $row) {
            $out[] = Snapshot::fromArray($row);
        }

        return $out;
    }

    /**
     * Snapshot a persistent disk.
     *
     * @return PendingAction<RunningOperation>
     */
    public function create(string $zone, string $disk, ?string $name = null): PendingAction
    {
        $zone = Validate::gcpName($zone, 'zone');
        $disk = Validate::gcpName($disk, 'disk');
        $name = Validate::gcpName($name ?? sprintf('%s-%s', substr($disk, 0, 40), gmdate('Ymd-His')), 'snapshot name');
        $path = "/projects/{$this->project}/zones/{$zone}/disks/{$disk}/createSnapshot";
        $body = ['name' => $name];

        return $this->transport->pending('snapshot disk', "{$zone}/{$disk} as {$name}", 'POST', $path, $body, fn (): RunningOperation => $this->operations->track(
            Operation::fromArray(Data::map(['op' => $this->transport->send('POST', $path, [], $body)->json], 'op')),
        ), note: 'billed per GB-month while it exists');
    }

    /**
     * Destructive.
     *
     * @return PendingAction<RunningOperation>
     */
    public function delete(string $name): PendingAction
    {
        $path = "/projects/{$this->project}/global/snapshots/".Validate::gcpName($name, 'snapshot name');

        return $this->transport->pending('delete snapshot', $name, 'DELETE', $path, [], fn (): RunningOperation => $this->operations->track(
            Operation::fromArray(Data::map(['op' => $this->transport->send('DELETE', $path)->json], 'op')),
        ), destructive: true);
    }
}
