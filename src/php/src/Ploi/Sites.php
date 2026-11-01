<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Ploi\Data\Site;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Validate;

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

    public const array PROJECT_TYPES = ['', 'laravel', 'nodejs', 'statamic', 'craft-cms', 'symfony', 'wordpress', 'octobercms', 'cakephp'];

    /**
     * Creates a site. Idempotent by domain: if the server already has it, nothing is sent.
     *
     * @return PendingAction<Site>
     */
    public function create(string $domain, string $webDirectory = '/public', string $projectType = '', string $systemUser = 'ploi'): PendingAction
    {
        $domain = Validate::domain($domain);
        if (preg_match('#^/[A-Za-z0-9/_.-]*$#', $webDirectory) !== 1 || str_contains($webDirectory, '..')) {
            throw new ValidationException(sprintf('web directory "%s" must be an absolute path inside the project, e.g. /public', $webDirectory));
        }
        if (! in_array($projectType, self::PROJECT_TYPES, true)) {
            throw new ValidationException(sprintf('project type must be one of: %s (or empty)', implode(', ', array_filter(self::PROJECT_TYPES))));
        }
        $systemUser = Validate::token($systemUser, 'system user');
        $path = "/servers/{$this->serverId}/sites";
        foreach ($this->list() as $site) {
            if ($site->domain === $domain) {
                return $this->transport->pending('create site', "{$domain} on server {$this->serverId} (already exists as site {$site->id})", 'NONE', $path, [], static fn (): Site => $site);
            }
        }
        $body = array_filter(['root_domain' => $domain, 'web_directory' => $webDirectory, 'project_root' => '/', 'system_user' => $systemUser, 'project_type' => $projectType], static fn (string $v): bool => $v !== '');

        return $this->transport->pending('create site', "{$domain} on server {$this->serverId}", 'POST', $path, $body,
            fn (): Site => Site::fromArray(Data::map($this->transport->send('POST', $path, [], $body)->json, 'data')),
            note: 'Ploi writes the nginx vhost; point DNS at the server and request a certificate afterwards');
    }

    /** @return PendingAction<bool> */
    public function delete(int|string $siteId): PendingAction
    {
        $site = $this->find($siteId);
        $path = "/servers/{$this->serverId}/sites/{$site->id}";

        return $this->transport->pending('delete site', "{$site->domain} ({$site->id}) on server {$this->serverId}", 'DELETE', $path, [],
            fn (): bool => $this->transport->send('DELETE', $path)->status < 300,
            destructive: true, note: 'removes the vhost and the site files on the server');
    }

    public function deployScript(int|string $siteId): string
    {
        $siteId = Validate::id($siteId, 'site id');
        $json = $this->transport->get("/servers/{$this->serverId}/sites/{$siteId}/deploy/script")->json;

        return Data::string($json, 'deploy_script', Data::string($json, 'data.deploy_script'));
    }

    /**
     * Replaces the deploy script. A no-op when it is already identical.
     *
     * @return PendingAction<bool>
     */
    public function setDeployScript(int|string $siteId, string $script): PendingAction
    {
        $siteId = Validate::id($siteId, 'site id');
        $script = str_replace("\r\n", "\n", $script);
        if (trim($script) === '') {
            throw new ValidationException('the deploy script is empty');
        }
        if (strlen($script) > 65_535) {
            throw new ValidationException('the deploy script is larger than 64 KiB');
        }
        $path = "/servers/{$this->serverId}/sites/{$siteId}/deploy/script";
        $current = $this->deployScript($siteId);
        if (rtrim($current) === rtrim($script)) {
            return $this->transport->pending('set deploy script', "site {$siteId} on server {$this->serverId}", 'NONE', $path, [], static fn (): bool => true);
        }
        $body = ['deploy_script' => $script];

        return $this->transport->pending('set deploy script', sprintf('site %d on server %d (%d lines, was %d)', $siteId, $this->serverId, substr_count(rtrim($script), "\n") + 1, $current === '' ? 0 : substr_count(rtrim($current), "\n") + 1),
            'PATCH', $path, $body, fn (): bool => $this->transport->send('PATCH', $path, [], $body)->status < 300,
            note: 'takes effect on the next deploy');
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
