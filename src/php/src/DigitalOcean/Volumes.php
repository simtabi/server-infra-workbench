<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Action;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/** Block storage volumes: extra disks you attach to a droplet in the same region. */
final readonly class Volumes
{
    private Endpoint $api;

    public function __construct(Transport $transport, private Actions $actions)
    {
        $this->api = new Endpoint($transport, 'volume', '/v2/volumes', new DigitalOceanPaginator('volumes'), [
            'id' => 'id', 'name' => 'name', 'region' => 'region.slug', 'sizeGb' => 'size_gigabytes',
            'dropletIds' => 'droplet_ids', 'filesystem' => 'filesystem_type', 'createdAt' => 'created_at',
        ], 'volume', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(?string $region = null): array
    {
        return $this->api->list($region === null ? [] : ['region' => Slug::of($region, 'region')]);
    }

    public function find(string $id): Item
    {
        return $this->api->get(Validate::token($id, 'volume id'));
    }

    /**
     * Idempotent by name and region.
     *
     * @param list<string> $tags
     * @return PendingAction<Item>
     */
    public function create(string $name, string $region, int $sizeGb, string $filesystem = 'ext4', array $tags = []): PendingAction
    {
        if (preg_match('/^[a-z][a-z0-9-]{0,63}$/', $name) !== 1) {
            throw new ValidationException(sprintf('volume name "%s" must start with a letter: lower-case letters, digits and - (max 64)', $name));
        }
        $region = Slug::of($region, 'region');
        Validate::range($sizeGb, 1, 16_384, 'size (GiB)');
        if (! in_array($filesystem, ['ext4', 'xfs', ''], true)) {
            throw new ValidationException('filesystem must be ext4, xfs or empty (unformatted)');
        }
        foreach ($this->api->rows(['name' => $name, 'region' => $region]) as $row) {
            if (Data::string($row, 'name') === $name) {
                return $this->api->noop('create volume', "\"{$name}\" (exists: ".Data::string($row, 'id').')', $this->api->item($row));
            }
        }
        $body = array_filter(['name' => $name, 'region' => $region, 'size_gigabytes' => $sizeGb, 'filesystem_type' => $filesystem,
            'tags' => array_map(static fn (string $t): string => Validate::label($t, 'tag'), $tags)], static fn (mixed $v): bool => $v !== '' && $v !== []);

        return $this->api->create($body, "\"{$name}\" {$sizeGb} GiB in {$region}", 'billed per GiB-month from creation, attached or not');
    }

    /**
     * Destructive: the data is gone. DigitalOcean refuses while the volume is attached.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $id): PendingAction
    {
        return $this->api->delete(Validate::token($id, 'volume id'), note: 'all data on the volume is lost; detach it first');
    }

    /** @return PendingAction<RunningAction> */
    public function attach(string $id, int|string $dropletId): PendingAction
    {
        return $this->action($id, ['type' => 'attach', 'droplet_id' => Validate::id($dropletId, 'droplet id')], 'attach volume', 'then mount it on the droplet (see the volume page for the mount commands)');
    }

    /**
     * Unmount it on the droplet first, or writes in flight are lost.
     *
     * @return PendingAction<RunningAction>
     */
    public function detach(string $id, int|string $dropletId): PendingAction
    {
        return $this->action($id, ['type' => 'detach', 'droplet_id' => Validate::id($dropletId, 'droplet id')], 'detach volume', 'unmount it on the droplet first (umount + remove the fstab line)');
    }

    /**
     * Grow a volume (it can never shrink), then grow the filesystem on the droplet (resize2fs / xfs_growfs).
     *
     * @return PendingAction<RunningAction>
     */
    public function resize(string $id, int $sizeGb): PendingAction
    {
        $volume = $this->find($id);
        if ($sizeGb <= $volume->int('sizeGb')) {
            throw new ValidationException(sprintf('volumes only grow: %d GiB is not larger than the current %d GiB', $sizeGb, $volume->int('sizeGb')));
        }

        return $this->action($id, ['type' => 'resize', 'size_gigabytes' => Validate::range($sizeGb, 1, 16_384, 'size (GiB)'), 'region' => $volume->string('region')],
            'resize volume', 'permanent (volumes cannot shrink); grow the filesystem afterwards', true);
    }

    /**
     * @param array<string, int|string> $body
     * @return PendingAction<RunningAction>
     */
    private function action(string $id, array $body, string $what, string $note, bool $destructive = false): PendingAction
    {
        $path = $this->api->path(Validate::token($id, 'volume id'), 'actions');
        $target = $id.(isset($body['droplet_id']) ? ' / droplet '.$body['droplet_id'] : '').(isset($body['size_gigabytes']) ? ' -> '.$body['size_gigabytes'].' GiB' : '');

        return $this->api->transport()->pending($what, $target, 'POST', $path, $body, fn (): RunningAction => $this->actions->track(
            Action::fromArray(Data::map($this->api->transport()->send('POST', $path, [], $body)->json, 'action')),
        ), $destructive, $note);
    }
}
