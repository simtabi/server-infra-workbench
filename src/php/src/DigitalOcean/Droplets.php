<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Action;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Droplet;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\DropletStatus;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Snapshot;
use Simtabi\VpsServerWorkbench\Exception\ActionFailedException;
use Simtabi\VpsServerWorkbench\Exception\TimeoutException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
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

    /**
     * Create a droplet. The plan (dry run) shows the exact body; nothing is created until confirm().
     * Idempotent by name: when a droplet with this name exists, confirm() returns it and sends nothing.
     *
     * @param list<int|string> $sshKeys   account key ids or fingerprints (see: workbench keys account list)
     * @param list<string>     $tags
     * @return PendingAction<Droplet>
     */
    public function create(string $name, string $region, string $size, string $image, array $sshKeys = [], ?string $vpcUuid = null, array $tags = [], bool $backups = false, ?string $userData = null): PendingAction
    {
        if (preg_match('/^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$/', $name) !== 1) {
            throw new ValidationException(sprintf('droplet name "%s" must be a hostname (letters, digits, . and -)', $name));
        }
        foreach (['region' => $region, 'size' => $size, 'image' => $image] as $what => $value) {
            if (preg_match('/^[a-z0-9][a-z0-9.-]{0,63}$/', $value) !== 1) {
                throw new ValidationException(sprintf('%s "%s" must be a DigitalOcean slug (e.g. nyc3, s-2vcpu-4gb, ubuntu-24-04-x64)', $what, $value));
            }
        }
        if ($sshKeys === []) {
            throw new ValidationException('refusing to create a droplet without an SSH key (--ssh-keys ID[,ID]); password logins are not used here');
        }
        foreach ($sshKeys as $key) {
            if (! (is_int($key) || ctype_digit($key) || preg_match('/^([0-9a-f]{2}:){15}[0-9a-f]{2}$/', $key) === 1)) {
                throw new ValidationException(sprintf('ssh key "%s" must be an id or an MD5 fingerprint', $key));
            }
        }
        $body = [
            'name' => $name, 'region' => $region, 'size' => $size, 'image' => $image,
            'ssh_keys' => array_values(array_map(static fn (int|string $k): int|string => is_string($k) && ctype_digit($k) ? (int) $k : $k, $sshKeys)),
            'backups' => $backups, 'ipv6' => true, 'monitoring' => true,
            'tags' => array_values(array_map(static fn (string $t): string => Validate::label($t, 'tag'), $tags)),
        ];
        if ($vpcUuid !== null) {
            $body['vpc_uuid'] = Validate::token($vpcUuid, 'vpc uuid');
        }
        if ($userData !== null) {
            $body['user_data'] = $userData;
        }
        foreach ($this->transport->paginate('/v2/droplets', ['per_page' => 200, 'name' => $name], new DigitalOceanPaginator('droplets')) as $row) {
            $existing = Droplet::fromArray($row);
            if ($existing->name === $name) {
                return $this->transport->pending('create droplet', "\"{$name}\" (exists: {$existing->id})", 'NONE', '/v2/droplets/'.$existing->id, [], static fn (): Droplet => $existing);
            }
        }

        return $this->transport->pending(
            'create droplet',
            "\"{$name}\" {$size} in {$region} ({$image})",
            'POST',
            '/v2/droplets',
            $body,
            fn (): Droplet => Droplet::fromArray(Data::map($this->transport->send('POST', '/v2/droplets', [], $body)->json, 'droplet')),
            note: "billed hourly from creation (size {$size}); see: workbench plans --regions {$region}",
        );
    }

    /**
     * Resize a droplet: graceful shutdown (power off if that fails), resize, power on, then return the droplet.
     * The droplet is down for the whole run (usually 1-5 minutes for CPU/RAM only). With $disk the disk grows
     * too: that cannot be undone (the droplet can never move to a smaller disk), so the action is destructive
     * and needs --force. Without $disk you can size down again later. Take a snapshot first.
     *
     * @return PendingAction<Droplet>
     */
    public function resize(int|string $id, string $size, bool $disk = false, int $timeoutSeconds = 1800): PendingAction
    {
        $id = Validate::id($id, 'droplet id');
        if (preg_match('/^[a-z0-9][a-z0-9.-]{0,63}$/', $size) !== 1) {
            throw new ValidationException(sprintf('size "%s" must be a DigitalOcean size slug (e.g. s-2vcpu-4gb; see: workbench plans)', $size));
        }
        $droplet = $this->find($id);
        $path = "/v2/droplets/{$id}/actions";
        $target = sprintf('%d "%s" %s -> %s%s', $id, $droplet->name, $droplet->size, $size, $disk ? ' (disk too, permanent)' : ' (CPU/RAM only)');
        if ($droplet->size === $size) {
            return $this->transport->pending('resize droplet', $target, 'NONE', $path, [], static fn (): Droplet => $droplet);
        }
        $body = ['type' => 'resize', 'size' => $size, 'disk' => $disk];
        $run = function () use ($id, $path, $body, $droplet, $timeoutSeconds): Droplet {
            $act = fn (array $b): Action => $this->actions->track(Action::fromArray(Data::map($this->transport->send('POST', $path, [], $b)->json, 'action')))->wait($timeoutSeconds);
            if ($droplet->status !== DropletStatus::Off) {
                try {
                    $act(['type' => 'shutdown']);
                } catch (ActionFailedException|TimeoutException) {
                    $act(['type' => 'power_off']);
                }
            }
            try {
                $act($body);
            } finally {
                if ($droplet->status !== DropletStatus::Off) {
                    $act(['type' => 'power_on']);
                }
            }

            return $this->find($id);
        };

        return $this->transport->pending('resize droplet', $target, 'POST', $path, $body, $run, destructive: $disk,
            note: 'downtime: shutdown, resize, power on (a few minutes). Snapshot first: workbench do snapshot '.$id.' --wait'.($disk ? '. Disk resize is permanent' : '. CPU/RAM only, reversible'));
    }
}
