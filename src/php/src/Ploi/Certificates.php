<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Item;
use Simtabi\ServerInfraWorkbench\Support\Validate;

/**
 * SSL certificates of one Ploi site (Let's Encrypt). DNS must already point at the server, or the
 * HTTP-01 challenge fails (and repeated failures hit Let's Encrypt rate limits).
 */
final readonly class Certificates
{
    private Endpoint $api;

    public function __construct(Transport $transport, private int $serverId, private int $siteId)
    {
        $this->api = new Endpoint($transport, 'certificate', "/servers/{$serverId}/sites/{$siteId}/certificates", new PloiPaginator, [
            'id' => 'id', 'domain' => 'domain', 'type' => 'type', 'status' => 'status', 'expiresAt' => 'expires_at',
        ], 'data', ['per_page' => 50]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * Request a Let's Encrypt certificate for the domains (comma list on Ploi's side).
     *
     * @param list<string> $domains
     * @return PendingAction<Item>
     */
    public function create(array $domains, bool $force = false): PendingAction
    {
        if ($domains === []) {
            throw new ValidationException('name the domain(s) for the certificate (--domain example.com,www.example.com)');
        }
        $domains = array_map(static fn (string $d): string => Validate::domain($d), $domains);
        foreach ($this->list() as $cert) {
            if (! $force && $cert->string('domain') === implode(',', $domains) && $cert->string('status') !== 'failed') {
                return $this->api->noop('request certificate', implode(', ', $domains)." (already certificate {$cert->int('id')})", $cert);
            }
        }

        return $this->api->create(['certificate' => implode(',', $domains), 'type' => 'letsencrypt', 'force' => $force],
            implode(', ', $domains)." on site {$this->siteId}", 'DNS must already resolve to the server; --force skips Ploi\'s DNS pre-check');
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $id): PendingAction
    {
        return $this->api->delete(Validate::id($id, 'certificate id'), "{$id} on site {$this->siteId}", 'the site falls back to HTTP (or a browser warning) until a new certificate is issued');
    }
}
