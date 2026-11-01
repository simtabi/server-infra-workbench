<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Cloudflare\Data\DnsRecord;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Droplet;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\Firewall;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\UptimeAlert;
use Simtabi\VpsServerWorkbench\DigitalOcean\Data\UptimeCheck;
use Simtabi\VpsServerWorkbench\DigitalOcean\Droplets;
use Simtabi\VpsServerWorkbench\DigitalOcean\FirewallPreset;
use Simtabi\VpsServerWorkbench\DigitalOcean\Monitoring;
use Simtabi\VpsServerWorkbench\DigitalOcean\RunningAction;
use Simtabi\VpsServerWorkbench\Exception\ApiException;
use Simtabi\VpsServerWorkbench\Exception\ConfirmationRequiredException;
use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Exception\WorkbenchException;
use Simtabi\VpsServerWorkbench\Gcp\RunningOperation;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Keys\PublicKey;
use Simtabi\VpsServerWorkbench\Keys\SshKey;
use Simtabi\VpsServerWorkbench\Ploi\Data\Daemon;
use Simtabi\VpsServerWorkbench\Ploi\Data\Site;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\Credentials;

/**
 * `bin/workbench do|cf|ploi|gcp|keys|health|credentials ...`
 *
 * Reads run straight away. Writes print what they will do and need --yes (or typing "yes" at the
 * prompt); destructive writes also need --force. --dry-run prints the plan and sends nothing.
 *
 * Exit codes: 0 ok, 1 provider/runtime error, 2 bad usage or input, 3 not confirmed, 4 credentials.
 */
final class Application
{
    public const int OK = 0;

    public const int FAILED = 1;

    public const int USAGE = 2;

    public const int NOT_CONFIRMED = 3;

    public const int CREDENTIALS = 4;

    private ProviderFactory $providers;

    private readonly Output $out;

    /** @var \Closure(string): bool */
    private readonly \Closure $prompt;

    /** @var \Closure(string): ?string */
    private readonly \Closure $reader;

    /**
     * @param (\Closure(string): bool)|null    $prompt Asks the user; default reads "yes" from a terminal.
     * @param (\Closure(string): ?string)|null $reader Reads one answer for the interactive keys menu (null = end of input).
     * @param Progress|null                    $progress Long waits (resize, snapshot --wait); default: detected from stderr + env.
     */
    public function __construct(?ProviderFactory $providers = null, ?Output $out = null, ?\Closure $prompt = null, ?\Closure $reader = null, private readonly ?Progress $progress = null)
    {
        $this->reader = $reader ?? self::terminalReader(...);
        $this->out = $out ?? new Output;
        $this->providers = $providers ?? new ProviderFactory(ClientOptions::defaults(), Credentials::fromEnvironment());
        $this->prompt = $prompt ?? self::terminalPrompt(...);
    }

    /** @param list<string> $argv */
    public function run(array $argv): int
    {
        try {
            $area = $argv[0] ?? 'help';
            $input = Input::parse(array_slice($argv, 1));
            if ($input->flag('verbose')) {
                $this->providers = $this->providers->withOptions($this->providers->options()->withLogger(new StderrLogger($this->out)));
            }
            $progress = $this->progress ?? ($input->flag('quiet') || $input->flag('json') ? Progress::off() : Progress::detect());
            if ($progress->mode() !== Progress::OFF) {
                $options = $this->providers->options();
                $this->providers = $this->providers->withOptions($options->withSleeper(new ProgressSleeper($options->sleeper(), $progress)));
            }
            if ($input->flag('help') && $area !== 'help') {
                $this->out->line(Help::for($area));

                return self::OK;
            }

            return match ($area) {
                'do', 'digitalocean' => $this->digitalOcean($input),
                'cf', 'cloudflare' => $this->cloudflare($input),
                'ploi' => $this->ploi($input),
                'gcp', 'gcloud' => $this->gcp($input),
                'keys' => $this->keys($input),
                'health' => $this->health($input),
                'credentials', 'creds' => $this->credentials($input),
                'help', '--help', '-h' => $this->help($input),
                'version', '--version' => $this->version(),
                default => throw new ValidationException(sprintf('unknown command "%s" (see: workbench help)', $area)),
            };
        } catch (ValidationException $e) {
            $this->out->error('error: '.$e->getMessage());

            return self::USAGE;
        } catch (ConfirmationRequiredException $e) {
            $this->out->error('not done: '.$e->getMessage());

            return self::NOT_CONFIRMED;
        } catch (CredentialException $e) {
            $this->out->error('credentials: '.$e->getMessage());

            return self::CREDENTIALS;
        } catch (ApiException $e) {
            $this->out->error('error: '.$e->getMessage());

            return self::FAILED;
        } catch (WorkbenchException $e) {
            $this->out->error('error: '.$e->getMessage());

            return self::FAILED;
        }
    }

    private function digitalOcean(Input $in): int
    {
        $do = fn () => $this->providers->digitalOcean();

        return match ($in->optionalArg(0)) {
            'droplets' => $this->show($in, $do()->droplets()->list($in->value('tag')), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'region' => 'REGION', 'size' => 'SIZE', 'publicIpv4' => 'PUBLIC IP', 'privateIpv4' => 'PRIVATE IP']),
            'droplet' => $this->showOne($in, $do()->droplets()->find($in->arg(1, 'droplet-id'))),
            'snapshots' => $this->show($in, $in->optionalArg(1) === null ? $do()->snapshots()->list() : $do()->droplets()->snapshots($in->arg(1, 'droplet-id')), ['id' => 'ID', 'name' => 'NAME', 'resourceId' => 'DROPLET', 'sizeGb' => 'GB', 'createdAt' => 'CREATED']),
            'snapshot' => $this->write($in, $do()->droplets()->snapshot($in->arg(1, 'droplet-id'), $in->value('name')), function (RunningAction $running) use ($in): int {
                $action = $in->flag('wait') ? $running->wait($in->int('timeout', 1800)) : $running->action();

                return $this->showOne($in, $action, $in->flag('wait') ? 'snapshot finished' : 'snapshot started (add --wait to wait for it)');
            }),
            'snapshot-delete' => $this->write($in, $do()->snapshots()->delete($in->arg(1, 'snapshot-id')), fn (bool $ok): int => $this->done($in, $ok, 'snapshot deleted')),
            'account' => $this->showOne($in, $do()->account()),
            'droplet-create' => $this->write($in, $do()->droplets()->create(
                $in->arg(1, 'name'),
                $in->value('region') ?? throw new ValidationException('--region is required (e.g. nyc3)'),
                $in->value('size') ?? throw new ValidationException('--size is required (e.g. s-2vcpu-4gb; see: workbench plans)'),
                $do()->droplets()->resolveImage($in->value('image') ?? $this->providers->credentials()->setting(Droplets::IMAGE_ENV)),
                $in->list('ssh-keys'),
                $in->value('vpc'),
                $in->list('tag'),
                $in->flag('backups'),
                $this->readFile($in->value('user-data')),
            ), fn (Droplet $d): int => $this->showOne($in, $d, 'droplet created (it boots in about a minute; see: workbench do droplet '.$d->id.')')),
            'resize' => $this->write($in, $do()->droplets()->resize($in->arg(1, 'droplet-id'), $in->value('size') ?? throw new ValidationException('--size is required (e.g. s-2vcpu-4gb; see: workbench plans)'), $in->flag('disk'), $in->int('timeout', 1800)),
                fn (Droplet $d): int => $this->showOne($in, $d, 'droplet resized and powered on')),
            'alerts' => match ($in->optionalArg(1)) {
                'list', null => $this->show($in, $do()->monitoring()->policies(), ['uuid' => 'UUID', 'description' => 'DESCRIPTION', 'enabled' => 'ENABLED', 'emails' => 'EMAILS']),
                'create' => $this->write($in, $do()->monitoring()->apply([Monitoring::body(
                    $in->value('type') ?? throw new ValidationException('--type is required ('.implode('|', array_keys(Monitoring::TYPES)).')'),
                    (float) ($in->value('value') ?? throw new ValidationException('--value is required (e.g. 85 for 85%)')),
                    $in->value('window') ?? '5m', $in->list('email'), $in->ints('droplet'), $in->list('tag'),
                    $in->flag('below') ? 'LessThan' : 'GreaterThan',
                )]), fn (array $p): int => $this->show($in, $p, ['uuid' => 'UUID', 'description' => 'DESCRIPTION'])),
                'standard' => $this->write($in, $do()->monitoring()->apply(Monitoring::standard($in->list('email'), $in->ints('droplet'), $in->list('tag'))),
                    fn (array $p): int => $p === [] ? $this->done($in, true, 'all standard alert policies already exist') : $this->show($in, $p, ['uuid' => 'UUID', 'description' => 'DESCRIPTION'])),
                'delete' => $this->write($in, $do()->monitoring()->delete($in->arg(2, 'policy-uuid')), fn (bool $ok): int => $this->done($in, $ok, 'alert policy deleted')),
                default => $this->usage('do'),
            },
            'firewalls' => $this->show($in, $do()->firewalls()->list(), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'dropletIds' => 'DROPLETS', 'tags' => 'TAGS', 'openToWorld' => 'WORLD-OPEN']),
            'firewall-apply' => $this->write($in, $do()->firewalls()->apply(FirewallPreset::build(
                $in->arg(1, 'db|web'),
                $in->value('name') ?? 'workbench-'.$in->arg(1, 'db|web'),
                $this->vpcCidr($in),
                $in->list('ssh-from'),
                $in->value('ports') === null ? FirewallPreset::DB_PORTS : $in->ints('ports'),
                $in->ints('droplet'),
                $in->list('tag'),
            )), fn (Firewall $f): int => $this->showOne($in, $f, 'firewall applied')),
            'firewall-delete' => $this->write($in, $do()->firewalls()->delete($in->arg(1, 'firewall-id')), fn (bool $ok): int => $this->done($in, $ok, 'firewall deleted')),
            'uptime' => match ($in->optionalArg(1)) {
                'checks', null => $this->show($in, $do()->uptime()->checks(), ['id' => 'ID', 'name' => 'NAME', 'type' => 'TYPE', 'target' => 'TARGET', 'regions' => 'REGIONS', 'enabled' => 'ENABLED']),
                'state' => $this->showOne($in, $do()->uptime()->state($in->arg(2, 'check-id'))),
                'check-create' => $this->write($in, $do()->uptime()->createCheck($in->arg(2, 'name'), $in->arg(3, 'url-or-host'), $in->value('type') ?? 'https', $in->list('regions') === [] ? \Simtabi\VpsServerWorkbench\DigitalOcean\Uptime::REGIONS : $in->list('regions')),
                    fn (UptimeCheck $c): int => $this->showOne($in, $c, 'uptime check saved')),
                'check-delete' => $this->write($in, $do()->uptime()->deleteCheck($in->arg(2, 'check-id')), fn (bool $ok): int => $this->done($in, $ok, 'uptime check deleted')),
                'alerts' => $this->show($in, $do()->uptime()->alerts($in->arg(2, 'check-id')), ['id' => 'ID', 'name' => 'NAME', 'type' => 'TYPE', 'threshold' => 'THRESHOLD', 'period' => 'PERIOD', 'emails' => 'EMAILS']),
                'alert-create' => $this->write($in, $do()->uptime()->createAlert($in->arg(2, 'check-id'), $in->arg(3, 'type'), $in->list('email'), $in->int('threshold', 0), $in->value('period') ?? '2m', $in->value('name')),
                    fn (UptimeAlert $a): int => $this->showOne($in, $a, 'uptime alert created')),
                default => $this->usage('do'),
            },
            null, 'help' => $this->usage('do'),
            default => throw new ValidationException(sprintf('unknown "do %s" (see: workbench do --help)', $in->arg(0, 'command'))),
        };
    }

    private function cloudflare(Input $in): int
    {
        $cf = fn () => $this->providers->cloudflare();

        return match ($in->optionalArg(0)) {
            'zones' => $this->show($in, $cf()->zones()->list(), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'plan' => 'PLAN']),
            'dns' => match ($in->optionalArg(1)) {
                'list' => $this->show($in, $cf()->dns($in->arg(2, 'zone'))->list($in->value('type'), $in->value('name')), ['id' => 'ID', 'type' => 'TYPE', 'name' => 'NAME', 'content' => 'CONTENT', 'ttl' => 'TTL', 'proxied' => 'PROXIED']),
                'upsert' => $this->write($in, $cf()->dns($in->arg(2, 'zone'))->upsert(
                    $in->arg(3, 'type'),
                    $in->arg(4, 'name'),
                    $in->arg(5, 'content'),
                    $in->int('ttl', 1),
                    $in->flag('proxied'),
                    $in->value('priority') === null ? null : $in->int('priority', 10),
                    $in->value('comment'),
                ), fn (DnsRecord $record): int => $this->showOne($in, $record, 'record saved')),
                'delete' => $this->write($in, $cf()->dns($in->arg(2, 'zone'))->delete($in->arg(3, 'record-id')), fn (bool $ok): int => $this->done($in, $ok, 'record deleted')),
                default => $this->usage('cf'),
            },
            'verify' => $this->done($in, $cf()->verifyToken() === 'active', 'token is active'),
            null, 'help' => $this->usage('cf'),
            default => throw new ValidationException(sprintf('unknown "cf %s" (see: workbench cf --help)', $in->arg(0, 'command'))),
        };
    }

    private function ploi(Input $in): int
    {
        $ploi = fn () => $this->providers->ploi();

        return match ($in->optionalArg(0)) {
            'servers' => $this->show($in, $ploi()->servers()->list(), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'ipAddress' => 'IP', 'internalIp' => 'PRIVATE IP', 'sitesCount' => 'SITES']),
            'server' => $this->showOne($in, $ploi()->servers()->get($in->arg(1, 'server-id'))),
            'sites' => $this->show($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->sites()->list(), ['id' => 'ID', 'domain' => 'DOMAIN', 'status' => 'STATUS', 'projectType' => 'TYPE', 'phpVersion' => 'PHP', 'lastDeployAt' => 'LAST DEPLOY']),
            'deploy' => $this->write($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->sites()->deploy($in->arg(2, 'site-id')), fn (bool $ok): int => $this->done($in, $ok, 'deploy queued on Ploi')),
            'site-create' => $this->write($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->sites()->create($in->arg(2, 'domain'), $in->value('web-directory') ?? '/public', $in->value('project-type') ?? '', $in->value('user') ?? 'ploi'),
                fn (Site $site): int => $this->showOne($in, $site, 'site created')),
            'site-delete' => $this->write($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->sites()->delete($in->arg(2, 'site-id')), fn (bool $ok): int => $this->done($in, $ok, 'site deleted')),
            'deploy-script' => $this->printScript($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->sites()->deployScript($in->arg(2, 'site-id'))),
            'deploy-script-set' => $this->write($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->sites()->setDeployScript($in->arg(2, 'site-id'),
                $this->readFile($in->value('file') ?? throw new ValidationException('--file <deploy.sh> is required')) ?? ''),
                fn (bool $ok): int => $this->done($in, $ok, 'deploy script saved')),
            'daemons' => $this->show($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->daemons()->list(), ['id' => 'ID', 'command' => 'COMMAND', 'systemUser' => 'USER', 'processes' => 'PROCS', 'status' => 'STATUS']),
            'daemon-create' => $this->write($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->daemons()->create(
                $in->value('command') ?? throw new ValidationException('--command is required (e.g. "php artisan queue:work")'),
                $in->value('user') ?? 'ploi', $in->int('processes', 1), $in->value('directory') ?? ''),
                fn (Daemon $d): int => $this->showOne($in, $d, 'daemon created')),
            'daemon-delete' => $this->write($in, $ploi()->servers()->find($in->arg(1, 'server-id'))->daemons()->delete($in->arg(2, 'daemon-id')), fn (bool $ok): int => $this->done($in, $ok, 'daemon deleted')),
            null, 'help' => $this->usage('ploi'),
            default => throw new ValidationException(sprintf('unknown "ploi %s" (see: workbench ploi --help)', $in->arg(0, 'command'))),
        };
    }

    private function gcp(Input $in): int
    {
        $gcp = fn () => $this->providers->gcp($in->value('project'));

        return match ($in->optionalArg(0)) {
            'instances' => $this->show($in, $gcp()->instances()->list($in->value('zone')), ['name' => 'NAME', 'zone' => 'ZONE', 'status' => 'STATUS', 'machineType' => 'TYPE', 'internalIp' => 'INTERNAL IP', 'externalIp' => 'EXTERNAL IP']),
            'snapshots' => $this->show($in, $gcp()->snapshots()->list(), ['name' => 'NAME', 'status' => 'STATUS', 'sourceDisk' => 'DISK', 'diskSizeGb' => 'GB', 'createdAt' => 'CREATED']),
            'firewalls' => $this->show($in, $gcp()->firewalls()->list(), ['name' => 'NAME', 'network' => 'NETWORK', 'direction' => 'DIR', 'allowed' => 'ALLOW', 'sourceRanges' => 'SOURCES', 'openToWorld' => 'WORLD-OPEN']),
            'snapshot' => $this->write($in, $gcp()->snapshots()->create($in->arg(1, 'zone'), $in->arg(2, 'disk'), $in->value('name')), function (RunningOperation $running) use ($in): int {
                $op = $in->flag('wait') ? $running->wait($in->int('timeout', 1800)) : $running->operation();

                return $this->showOne($in, $op, $in->flag('wait') ? 'snapshot finished' : 'snapshot started (add --wait to wait for it)');
            }),
            null, 'help' => $this->usage('gcp'),
            default => throw new ValidationException(sprintf('unknown "gcp %s" (see: workbench gcp --help)', $in->arg(0, 'command'))),
        };
    }

    /** `workbench health <url>...`: exit 0 only when every endpoint passes. */
    private function health(Input $in): int
    {
        $urls = $in->args();
        if ($urls === []) {
            return $this->usage('health');
        }
        $check = $this->providers->health();
        $results = array_map(fn (string $url) => $check->check($url, $in->int('expect', 200), $in->value('contains'), $in->value('max-ms') === null ? null : $in->int('max-ms', 0)), $urls);
        if ($in->flag('json')) {
            $this->out->json(array_map(self::row(...), $results));
        } else {
            $rows = array_map(static fn ($r): array => ['result' => $r->ok ? 'ok' : 'FAIL', 'url' => $r->url, 'status' => $r->status ?? '-', 'ms' => $r->ms, 'problems' => implode('; ', $r->problems)], $results);
            $this->out->table($rows, ['result' => 'RESULT', 'url' => 'URL', 'status' => 'STATUS', 'ms' => 'MS', 'problems' => 'PROBLEMS']);
        }

        return array_filter($results, static fn ($r): bool => ! $r->ok) === [] ? self::OK : self::FAILED;
    }

    private function keys(Input $in): int
    {
        $config = $in->value('config');

        return match ($in->optionalArg(0)) {
            null => $this->keysMenu($in),
            'providers' => $this->keyProviderList($in, $config),
            'account' => $this->accountKeys($in, $config),
            'server' => $this->serverKeys($in),
            'fingerprint' => $this->showOne($in, (static fn (PublicKey $k): array => ['type' => $k->type, 'comment' => $k->comment, 'sha256' => $k->fingerprint(), 'md5' => $k->md5()])(PublicKey::parse($this->publicKey($in)))),
            'help' => $this->usage('keys'),
            default => throw new ValidationException(sprintf('unknown "keys %s" (see: workbench keys --help)', $in->arg(0, 'command'))),
        };
    }

    private function keyProviderList(Input $in, ?string $config): int
    {
        $providers = $this->providers->keyProviders($config);
        $available = $providers->available($this->providers->credentials());
        $rows = [];
        foreach ($providers->names() as $name) {
            $spec = $providers->spec($name);
            $rows[] = ['provider' => $name, 'configured' => in_array($name, $available, true), 'token' => $spec->tokenEnv.($spec->scopeEnv !== '' ? ' + '.$spec->scopeEnv : ''), 'api' => $spec->baseUrl];
        }
        $in->flag('json') ? $this->out->json($rows) : $this->out->table($rows, ['provider' => 'PROVIDER', 'configured' => 'CONFIGURED', 'token' => 'CREDENTIALS', 'api' => 'API']);

        return self::OK;
    }

    private function accountKeys(Input $in, ?string $config): int
    {
        $keys = fn () => $this->providers->accountKeys($in->value('provider') ?? throw new ValidationException('--provider is required (see: workbench keys providers)'), $config);

        return match ($in->optionalArg(1)) {
            'list', null => $this->show($in, $keys()->list(), ['id' => 'ID', 'name' => 'NAME', 'fingerprint' => 'FINGERPRINT']),
            'add' => $this->write($in, $keys()->add($in->value('name') ?? throw new ValidationException('--name is required'), $this->publicKey($in)),
                fn (SshKey $k): int => $this->showOne($in, $k, 'key on the account')),
            'rename' => $this->write($in, $keys()->rename($in->arg(2, 'key-id'), $in->value('name') ?? throw new ValidationException('--name is required')), fn (bool $ok): int => $this->done($in, $ok, 'key renamed')),
            'remove', 'delete' => $this->write($in, $keys()->remove($in->arg(2, 'key-id')), fn (bool $ok): int => $this->done($in, $ok, 'key removed from the account (servers keep it)')),
            default => $this->usage('keys'),
        };
    }

    private function serverKeys(Input $in): int
    {
        $server = fn () => $this->providers->serverKeys($in->value('host') ?? throw new ValidationException('--host user@host is required'), $this->sshOptions($in));

        return match ($in->optionalArg(1)) {
            'list', null => $this->serverKeyList($in, $server()),
            'add' => $this->write($in, $server()->add($this->publicKey($in)), fn (string $backup): int => $this->done($in, true, $backup === '' ? 'already there; nothing changed' : "key added (backup: ~/.ssh/{$backup}). Keep this session open and test a new login.")),
            'remove' => $this->write($in, $server()->remove($in->arg(2, 'number|fingerprint|comment'), $in->flag('force')), fn (string $backup): int => $this->done($in, true, "key removed (backup: ~/.ssh/{$backup}); a fresh login was tested")),
            'fix-perms', 'fix-permissions' => $this->write($in, $server()->fixPermissions(), fn (string $unused): int => $this->done($in, true, 'permissions fixed')),
            default => $this->usage('keys'),
        };
    }

    private function serverKeyList(Input $in, \Simtabi\VpsServerWorkbench\Keys\ServerKeys $server): int
    {
        $session = $server->sessionFingerprint();
        $rows = [];
        foreach ($server->entries() as $i => $entry) {
            $rows[] = ['n' => $i + 1, 'type' => $entry['key']->type, 'comment' => $entry['key']->comment, 'fingerprint' => $entry['key']->fingerprint(),
                'options' => $entry['key']->options, 'session' => $entry['key']->fingerprint() === $session];
        }
        if ($in->flag('json')) {
            $this->out->json(['host' => $server->target(), 'sessionKey' => $session, 'keys' => $rows]);
        } else {
            $this->out->table($rows, ['n' => '#', 'type' => 'TYPE', 'comment' => 'COMMENT', 'fingerprint' => 'FINGERPRINT', 'session' => 'THIS SESSION']);
            $this->out->line($session === null ? '(could not tell which key this session uses)' : "this session logged in with {$session}; it can't be removed");
        }

        return self::OK;
    }

    /** The interactive menu: same operations, same safety checks, prompts instead of flags. */
    private function keysMenu(Input $in): int
    {
        $ask = function (string $question): string {
            $answer = ($this->reader)($question);
            if ($answer === null) {
                throw new MenuClosed;
            }

            return trim($answer);
        };
        try {
            while (true) {
                $top = $ask("\nSSH keys\n  1) account keys (provider dashboards)\n  2) server keys (~/.ssh/authorized_keys)\n  q) quit\n> ");
                if ($top === 'q' || $top === '') {
                    return self::OK;
                }
                try {
                    match ($top) {
                        '1' => $this->accountMenu($in, $ask),
                        '2' => $this->serverMenu($in, $ask),
                        default => $this->out->line('pick 1, 2 or q'),
                    };
                } catch (ValidationException|ConfirmationRequiredException|ApiException|CredentialException $e) {
                    $this->out->error('error: '.$e->getMessage());
                }
            }
        } catch (MenuClosed) {
            $this->out->line('');

            return self::OK;
        }
    }

    /**
     * @param \Closure(string): string $ask
     */
    private function accountMenu(Input $in, \Closure $ask): void
    {
        $providers = $this->providers->keyProviders($in->value('config'));
        $names = $providers->names();
        $this->out->line('providers: '.implode(', ', $names).' (configured: '.implode(', ', $providers->available($this->providers->credentials())).')');
        $provider = $ask('provider> ');
        $keys = $this->providers->accountKeys($provider, $in->value('config'));
        while (true) {
            $choice = $ask("\n{$provider} account keys\n  1) list  2) add  3) rename  4) delete  b) back\n> ");
            match ($choice) {
                '1' => $this->out->table(array_map(self::row(...), $keys->list()), ['id' => 'ID', 'name' => 'NAME', 'fingerprint' => 'FINGERPRINT']),
                '2' => $this->menuConfirm($in, $ask, $keys->add($ask('name> '), $this->keyFromAnswer($ask('public key file [~/.ssh/id_ed25519.pub] or paste the key> ')))),
                '3' => $this->menuConfirm($in, $ask, $keys->rename($ask('key id> '), $ask('new name> '))),
                '4' => (function () use ($in, $keys, $ask): void {
                    $this->out->line('note: servers that already have this key keep it.');
                    $this->menuConfirm($in, $ask, $keys->remove($ask('key id> ')));
                })(),
                'b', '' => null,
                default => $this->out->line('pick 1-4 or b'),
            };
            if ($choice === 'b' || $choice === '') {
                return;
            }
        }
    }

    /**
     * @param \Closure(string): string $ask
     */
    private function serverMenu(Input $in, \Closure $ask): void
    {
        $server = $this->providers->serverKeys($ask('host (user@host or ssh alias)> '), $this->sshOptions($in));
        $this->out->line('keep this terminal session open until you have tested a new login.');
        while (true) {
            $choice = $ask("\n{$server->target()} authorized_keys\n  1) list  2) add  3) remove  4) fix permissions  b) back\n> ");
            match ($choice) {
                '1' => $this->serverKeyList($in, $server),
                '2' => $this->menuConfirm($in, $ask, $server->add($this->keyFromAnswer($ask('public key file [~/.ssh/id_ed25519.pub] or paste the key> ')))),
                '3' => (function () use ($in, $server, $ask): void {
                    $this->serverKeyList(Input::parse([]), $server);
                    $selector = $ask('number to remove> ');
                    try {
                        $action = $server->remove($selector);
                    } catch (ConfirmationRequiredException $e) {
                        $this->out->error('warning: '.$e->getMessage());
                        if ($ask('remove it anyway? type force: ') !== 'force') {
                            $this->out->line('cancelled; nothing changed');

                            return;
                        }
                        $action = $server->remove($selector, true);
                    }
                    $this->menuConfirm($in, $ask, $action);
                })(),
                '4' => $this->menuConfirm($in, $ask, $server->fixPermissions()),
                'b', '' => null,
                default => $this->out->line('pick 1-4 or b'),
            };
            if ($choice === 'b' || $choice === '') {
                return;
            }
        }
    }

    /**
     * @template T
     *
     * @param \Closure(string): string $ask
     * @param PendingAction<T>         $action
     */
    private function menuConfirm(Input $in, \Closure $ask, PendingAction $action): void
    {
        if ($in->flag('dry-run')) {
            $action->plan();
            $this->out->line('DRY RUN — nothing sent. Would do: '.$action->describe());

            return;
        }
        if (! $action->isNoop() && $ask($action->describe()."\nType yes to continue: ") !== 'yes') {
            $this->out->line('cancelled; nothing changed');

            return;
        }
        $action->confirm();
        $this->out->line($action->isNoop() ? 'no change needed' : 'done: '.$action->describe());
    }

    private function keyFromAnswer(string $answer): string
    {
        if ($answer === '') {
            $answer = '~/.ssh/id_ed25519.pub';
        }

        return PublicKey::isValid($answer) ? $answer : $this->readPublicKeyFile($answer);
    }

    /** --public-key "ssh-ed25519 AAAA...", else --key-file F, else ~/.ssh/id_ed25519.pub. */
    private function publicKey(Input $in): string
    {
        $inline = $in->value('public-key');
        if ($inline !== null) {
            return PublicKey::parse($inline)->line();
        }

        return $this->readPublicKeyFile($in->value('key-file') ?? '~/.ssh/id_ed25519.pub');
    }

    /** Reads a PUBLIC key file. Refuses anything that looks like a private key, without echoing it. */
    private function readPublicKeyFile(string $file): string
    {
        if (str_starts_with($file, '~/')) {
            $file = (string) getenv('HOME').substr($file, 1);
        }
        if (! str_ends_with($file, '.pub')) {
            throw new ValidationException(sprintf('"%s": pass the public half (a .pub file); private keys are never read', $file));
        }
        if (! is_file($file) || ! is_readable($file)) {
            throw new ValidationException(sprintf('no readable public key at %s', $file));
        }
        $line = trim((string) file_get_contents($file, length: 16_384));
        if (str_contains($line, 'PRIVATE KEY')) {
            throw new ValidationException(sprintf('%s contains a private key; refusing to use it', $file));
        }

        return PublicKey::parse($line)->line();
    }

    /** @return list<string> */
    private function sshOptions(Input $in): array
    {
        $raw = trim($in->value('ssh-opt') ?? '');

        $parts = $raw === '' ? false : preg_split('/\s+/', $raw);

        return $parts === false ? [] : $parts;
    }

    private function vpcCidr(Input $in): string
    {
        $vpc = $in->value('vpc') ?? throw new ValidationException('--vpc is required: a VPC id (looked up) or its CIDR, e.g. 10.0.0.0/20');

        return str_contains($vpc, '/') ? FirewallPreset::cidr($vpc) : $this->providers->digitalOcean()->firewalls()->vpcCidr($vpc);
    }

    private function readFile(?string $file): ?string
    {
        if ($file === null) {
            return null;
        }
        if (! is_file($file) || ! is_readable($file)) {
            throw new ValidationException(sprintf('cannot read %s', $file));
        }
        if (filesize($file) > 65_536) {
            throw new ValidationException(sprintf('%s is larger than 64 KiB', $file));
        }

        return (string) file_get_contents($file);
    }

    private function printScript(Input $in, string $script): int
    {
        $in->flag('json') ? $this->out->json(['deployScript' => $script]) : $this->out->line(rtrim($script));

        return self::OK;
    }

    /** Which credentials are configured and where from. Never prints a value. */
    private function credentials(Input $in): int
    {
        $store = $this->providers->credentials();
        $rows = [];
        foreach (Credentials::KEYS as $key => $what) {
            $rows[] = ['key' => $key, 'source' => $store->source($key) ?? 'missing', 'what' => $what];
        }
        $problems = $store->fileProblems();
        if ($in->flag('json')) {
            $this->out->json(['file' => $store->file(), 'exists' => $store->file() !== null && is_file($store->file()), 'problems' => $problems, 'keys' => $rows]);
        } else {
            $this->out->line('credentials file: '.($store->file() ?? '(none)').($store->file() !== null && is_file($store->file()) ? '' : ' (not present)'));
            $this->out->table($rows, ['key' => 'KEY', 'source' => 'SOURCE', 'what' => 'FOR']);
            foreach ($problems as $problem) {
                $this->out->error('warning: '.$problem);
            }
        }

        return $problems === [] ? self::OK : self::CREDENTIALS;
    }

    /**
     * The one path every write takes.
     *
     * @template T
     *
     * @param PendingAction<T>  $action
     * @param \Closure(T): int   $present
     */
    private function write(Input $in, PendingAction $action, \Closure $present): int
    {
        if ($in->flag('dry-run')) {
            $plan = $action->plan();
            if ($in->flag('json')) {
                $this->out->json(['dryRun' => true] + $plan);
            } else {
                $this->out->line('DRY RUN — nothing sent. Would do: '.$action->describe());
                if ($plan['payload'] !== []) {
                    $this->out->line('  payload: '.json_encode($plan['payload'], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
                }
                if ($plan['note'] !== null) {
                    $this->out->line('  note: '.$plan['note']);
                }
            }

            return self::OK;
        }
        if (! $action->isNoop()) {
            if ($action->isDestructive() && ! $in->flag('force')) {
                throw new ConfirmationRequiredException($action->describe().' is destructive; re-run with --force --yes (or --dry-run to preview)');
            }
            if (! $in->flag('yes') && ! ($this->prompt)($action->describe())) {
                throw new ConfirmationRequiredException($action->describe().' was not confirmed; pass --yes to run without the prompt, or --dry-run to preview');
            }
        }

        return $present($action->confirm());
    }

    /**
     * @param list<\JsonSerializable> $items
     * @param array<string, string>   $columns
     */
    private function show(Input $in, array $items, array $columns): int
    {
        $rows = array_map(static fn (\JsonSerializable $item): array => self::row($item), $items);
        $in->flag('json') ? $this->out->json($rows) : $this->out->table($rows, $columns);

        return self::OK;
    }

    /** @param \JsonSerializable|array<string, mixed> $item */
    private function showOne(Input $in, \JsonSerializable|array $item, ?string $message = null): int
    {
        $row = is_array($item) ? $item : self::row($item);
        if ($in->flag('json')) {
            $this->out->json($row);
        } else {
            if ($message !== null) {
                $this->out->line($message);
            }
            $width = $row === [] ? 0 : max(array_map(strlen(...), array_keys($row)));
            foreach ($row as $key => $value) {
                $this->out->line(sprintf('  %-'.$width.'s  %s', $key, is_scalar($value) || $value === null ? var_export($value, true) : json_encode($value, JSON_UNESCAPED_SLASHES)));
            }
        }

        return self::OK;
    }

    private function done(Input $in, bool $ok, string $message): int
    {
        $in->flag('json') ? $this->out->json(['ok' => $ok, 'message' => $message]) : $this->out->line($ok ? $message : 'failed: '.$message);

        return $ok ? self::OK : self::FAILED;
    }

    private function help(Input $in): int
    {
        $this->out->line(Help::for($in->optionalArg(0) ?? 'main'));

        return self::OK;
    }

    private function usage(string $area): int
    {
        $this->out->line(Help::for($area));

        return self::USAGE;
    }

    private function version(): int
    {
        $this->out->line('vps-server-workbench '.ClientOptions::VERSION.' (PHP '.PHP_VERSION.')');

        return self::OK;
    }

    /** @return array<string, mixed> */
    private static function row(\JsonSerializable $item): array
    {
        $data = $item->jsonSerialize();
        $row = [];
        if (is_array($data)) {
            foreach ($data as $key => $value) {
                $row[(string) $key] = $value;
            }
        }

        return $row;
    }

    private static function terminalReader(string $question): ?string
    {
        if (! stream_isatty(STDIN)) {
            return null;
        }
        fwrite(STDERR, $question);
        $answer = fgets(STDIN);

        return is_string($answer) ? rtrim($answer, "\r\n") : null;
    }

    private static function terminalPrompt(string $description): bool
    {
        if (! stream_isatty(STDIN)) {
            return false;
        }
        fwrite(STDERR, $description."\nType yes to continue: ");
        $answer = fgets(STDIN);

        return is_string($answer) && trim($answer) === 'yes';
    }
}
