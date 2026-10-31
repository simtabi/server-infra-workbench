<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Action;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Droplet;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Snapshot;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Droplets
{
    public function __construct(private Transport $transport, private Actions $actions) {}

    /** @return list<Droplet> */
    public function list(?string $tag = null): array
    {
        $query = ['per_page' => 200];
        if ($tag !== null) {
            $query['tag_name'] = Validate::label($tag, 'tag');
        }
        $out = [];
        foreach ($this->transport->paginate('/v2/droplets', $query, new DigitalOceanPaginator('droplets')) as $row) {
            $out[] = Droplet::fromArray($row);
        }

        return $out;
    }

    public function find(int|string $id): Droplet
    {
        return Droplet::fromArray(Data::map($this->transport->get('/v2/droplets/'.Validate::id($id, 'droplet id'))->json, 'droplet'));
    }

    /** @return list<Snapshot> */
    public function snapshots(int|string $id): array
    {
        $path = '/v2/droplets/'.Validate::id($id, 'droplet id').'/snapshots';
        $out = [];
        foreach ($this->transport->paginate($path, ['per_page' => 200], new DigitalOceanPaginator('snapshots')) as $row) {
            $out[] = Snapshot::fromArray($row);
        }

        return $out;
    }

    /**
     * Snapshot a droplet. Nothing happens until ->confirm(), which returns a RunningAction you can ->wait() on.
     * DigitalOcean recommends powering off first for a crash-consistent image; live snapshots work but
     * a database should be quiesced (the db manager's savepoint/backup covers that).
     *
     * @return PendingAction<RunningAction>
     */
    public function snapshot(int|string $id, ?string $name = null): PendingAction
    {
        $id = Validate::id($id, 'droplet id');
        $name = Validate::label($name ?? sprintf('workbench-%d-%s', $id, gmdate('Ymd-His')), 'snapshot name');
        $path = "/v2/droplets/{$id}/actions";
        $body = ['type' => 'snapshot', 'name' => $name];

        return $this->transport->pending(
            'snapshot droplet',
            "{$id} as \"{$name}\"",
            'POST',
            $path,
            $body,
            fn (): RunningAction => $this->actions->track(
                Action::fromArray(Data::map($this->transport->send('POST', $path, [], $body)->json, 'action')),
            ),
            note: 'billed per GB-month while it exists',
        );
    }
}
