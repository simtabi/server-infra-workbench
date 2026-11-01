<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console\Commands;

use Simtabi\VpsServerWorkbench\Console\Input;
use Simtabi\VpsServerWorkbench\Console\ProviderFactory;
use Simtabi\VpsServerWorkbench\Console\Runner;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Ploi\Data\Daemon;
use Simtabi\VpsServerWorkbench\Ploi\Data\Site;
use Simtabi\VpsServerWorkbench\Ploi\ServerResource;
use Simtabi\VpsServerWorkbench\Security\IssuedCredential;
use Simtabi\VpsServerWorkbench\Support\Item;

/** `workbench ploi ...`: Ploi API v1. */
final readonly class PloiCommand implements Command
{
    public function __construct(private ProviderFactory $providers, private Runner $r) {}

    public function run(Input $in): int
    {
        $r = $this->r;
        $server = fn (): ServerResource => $this->providers->ploi()->servers()->find($in->arg(1, 'server-id'));

        return match ($in->optionalArg(0)) {
            'servers' => $r->show($in, $this->providers->ploi()->servers()->list(), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'ipAddress' => 'IP', 'internalIp' => 'PRIVATE IP', 'sitesCount' => 'SITES']),
            'server' => $r->showOne($in, $this->providers->ploi()->servers()->get($in->arg(1, 'server-id'))),
            'server-restart' => $r->write($in, $server()->restart(), fn (bool $ok): int => $r->done($in, $ok, 'server restart queued')),
            'sites' => $r->show($in, $server()->sites()->list(), ['id' => 'ID', 'domain' => 'DOMAIN', 'status' => 'STATUS', 'projectType' => 'TYPE', 'phpVersion' => 'PHP', 'lastDeployAt' => 'LAST DEPLOY']),
            'site' => $r->showOne($in, $server()->sites()->find($in->arg(2, 'site-id'))),
            'site-create' => $r->write($in, $server()->sites()->create($in->arg(2, 'domain'), $in->value('web-directory') ?? '/public', $in->value('project-type') ?? '', $in->value('user') ?? 'ploi'),
                fn (Site $site): int => $r->showOne($in, $site, 'site created')),
            'site-delete' => $r->write($in, $server()->sites()->delete($in->arg(2, 'site-id')), fn (bool $ok): int => $r->done($in, $ok, 'site deleted')),
            'deploy' => $r->write($in, $server()->sites()->deploy($in->arg(2, 'site-id')), fn (bool $ok): int => $r->done($in, $ok, 'deploy queued on Ploi')),
            'deploy-script' => $r->printScript($in, $server()->sites()->deployScript($in->arg(2, 'site-id'))),
            'deploy-script-set' => $r->write($in, $server()->sites()->setDeployScript($in->arg(2, 'site-id'), $r->readFile($in->required('file', '<deploy.sh>')) ?? ''),
                fn (bool $ok): int => $r->done($in, $ok, 'deploy script saved')),
            'daemons' => $r->show($in, $server()->daemons()->list(), ['id' => 'ID', 'command' => 'COMMAND', 'systemUser' => 'USER', 'processes' => 'PROCS', 'status' => 'STATUS']),
            'daemon-create' => $r->write($in, $server()->daemons()->create($in->required('command', 'e.g. "php artisan queue:work"'), $in->value('user') ?? 'ploi', $in->int('processes', 1), $in->value('directory') ?? ''),
                fn (Daemon $d): int => $r->showOne($in, $d, 'daemon created')),
            'daemon-delete' => $r->write($in, $server()->daemons()->delete($in->arg(2, 'daemon-id')), fn (bool $ok): int => $r->done($in, $ok, 'daemon deleted')),
            'crons' => $r->show($in, $server()->crontabs()->list(), ['id' => 'ID', 'frequency' => 'SCHEDULE', 'command' => 'COMMAND', 'user' => 'USER', 'status' => 'STATUS']),
            'cron-create' => $r->write($in, $server()->crontabs()->create($in->required('command', 'e.g. "php artisan schedule:run"'), $in->required('frequency', 'e.g. "* * * * *" or @daily'), $in->value('user') ?? 'ploi'),
                fn (Item $i): int => $r->showOne($in, $i, 'cron job created')),
            'cron-delete' => $r->write($in, $server()->crontabs()->delete($in->arg(2, 'cron-id')), fn (bool $ok): int => $r->done($in, $ok, 'cron job deleted')),
            'databases' => $r->show($in, $server()->databases()->list(), ['id' => 'ID', 'name' => 'NAME', 'type' => 'TYPE', 'siteId' => 'SITE', 'status' => 'STATUS']),
            'database-create' => (function () use ($in, $r, $server): int {
                $user = $in->value('user');
                $path = $user === null || $in->flag('dry-run') ? '' : $r->outPath($in, 'database password');
                $action = $server()->databases()->create($in->arg(2, 'name'), $user, $in->value('site') === null ? null : $in->int('site', 0), $in->value('description') ?? '');
                if ($user === null) {
                    return $r->write($in, $action, fn (Item|IssuedCredential $db): int => $r->showOne($in, $db, 'database created'));
                }

                return $r->write($in, $action, fn (Item|IssuedCredential $c): int => $c instanceof IssuedCredential ? $r->issued($in, $c, $path, 'database created') : $r->showOne($in, $c, 'database created'));
            })(),
            'database-delete' => $r->write($in, $server()->databases()->delete($in->arg(2, 'database-id')), fn (bool $ok): int => $r->done($in, $ok, 'database deleted')),
            'certs' => $r->show($in, $server()->certificates($in->arg(2, 'site-id'))->list(), ['id' => 'ID', 'domain' => 'DOMAINS', 'type' => 'TYPE', 'status' => 'STATUS', 'expiresAt' => 'EXPIRES']),
            'cert-create' => $r->write($in, $server()->certificates($in->arg(2, 'site-id'))->create($in->list('domain'), $in->flag('force')),
                fn (Item $i): int => $r->showOne($in, $i, 'certificate requested (Ploi issues it in the background)')),
            'cert-delete' => $r->write($in, $server()->certificates($in->arg(2, 'site-id'))->delete($in->arg(3, 'certificate-id')), fn (bool $ok): int => $r->done($in, $ok, 'certificate deleted')),
            null, 'help' => $r->usage('ploi'),
            default => throw new ValidationException(sprintf('unknown "ploi %s" (see: workbench ploi --help)', $in->arg(0, 'command'))),
        };
    }
}
