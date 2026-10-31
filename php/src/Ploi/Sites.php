<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Ploi;

use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Ploi\Data\Site;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Validate;

final readonly class Sites
{
    public function __construct(private Transport $transport, private int $serverId) {}

    /** @return list<Site> */
    public function list(): array
    {
        $out = [];
        foreach ($this->transport->paginate("/servers/{$this->serverId}/sites", ['per_page' => 50], new PloiPaginator) as $row) {
            $out[] = Site::fromArray($row);
        }

        return $out;
    }

    public function find(int|string $siteId): Site
    {
        $siteId = Validate::id($siteId, 'site id');

        return Site::fromArray(Data::map($this->transport->get("/servers/{$this->serverId}/sites/{$siteId}")->json, 'data'));
    }

    /**
     * Runs the site's deploy script on Ploi.
     *
     * @return PendingAction<bool>
     */
    public function deploy(int|string $siteId): PendingAction
    {
        $siteId = Validate::id($siteId, 'site id');
        $path = "/servers/{$this->serverId}/sites/{$siteId}/deploy";

        return $this->transport->pending(
            'deploy site',
            "{$siteId} on server {$this->serverId}",
            'POST',
            $path,
            [],
            fn (): bool => $this->transport->send('POST', $path, [], [])->status < 300,
            note: 'runs the deploy script configured in Ploi',
        );
    }
}
