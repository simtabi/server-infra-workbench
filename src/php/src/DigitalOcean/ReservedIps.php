<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean;

use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\Action;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Item;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/**
 * Reserved (formerly floating) IPv4 addresses: a public IP you can move between droplets in a region,
 * so DNS never has to change during a failover or a rebuild.
 */
final readonly class ReservedIps
{
    private Endpoint $api;

    public function __construct(Transport $transport, private Actions $actions)
    {
        $this->api = new Endpoint($transport, 'reserved ip', '/v2/reserved_ips', new DigitalOceanPaginator('reserved_ips'), [
            'ip' => 'ip', 'region' => 'region.slug', 'dropletId' => 'droplet.id', 'dropletName' => 'droplet.name', 'locked' => 'locked',
        ], 'reserved_ip', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * Reserve an IP in a region, or one already assigned to a droplet.
     *
     * @return PendingAction<Item>
     */
    public function create(?string $region = null, int|string|null $dropletId = null): PendingAction
    {
        if (($region === null) === ($dropletId === null)) {
            throw new ValidationException('give either --region (unassigned) or --droplet (assign at once), not both');
        }
        $body = $region !== null ? ['region' => Slug::of($region, 'region')] : ['droplet_id' => Validate::id($dropletId ?? 0, 'droplet id')];

        return $this->api->create($body, $region !== null ? "in {$region}" : "for droplet {$dropletId}", 'billed hourly while it is NOT assigned to a droplet');
    }

    /** @return PendingAction<RunningAction> */
    public function assign(string $ip, int|string $dropletId): PendingAction
    {
        return $this->action($ip, ['type' => 'assign', 'droplet_id' => Validate::id($dropletId, 'droplet id')], 'traffic to the IP moves to this droplet within seconds');
    }

    /** @return PendingAction<RunningAction> */
    public function unassign(string $ip): PendingAction
    {
        return $this->action($ip, ['type' => 'unassign'], 'traffic to the IP stops until it is assigned again', true);
    }

    /**
     * Destructive: the address goes back to the pool and is unlikely to come back.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $ip): PendingAction
    {
        return $this->api->delete(self::ip($ip), note: 'the address is released; DNS pointing at it breaks');
    }

    /**
     * @param array<string, int|string> $body
     * @return PendingAction<RunningAction>
     */
    private function action(string $ip, array $body, string $note, bool $destructive = false): PendingAction
    {
        $path = $this->api->path(self::ip($ip), 'actions');

        return $this->api->transport()->pending($body['type'].' reserved ip', $ip.(isset($body['droplet_id']) ? ' -> droplet '.$body['droplet_id'] : ''), 'POST', $path, $body,
            fn (): RunningAction => $this->actions->track(Action::fromArray(Data::map($this->api->transport()->send('POST', $path, [], $body)->json, 'action'))),
            $destructive, $note);
    }

    private static function ip(string $ip): string
    {
        if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
            throw new ValidationException(sprintf('"%s" is not an IPv4 address', substr($ip, 0, 60)));
        }

        return $ip;
    }
}
