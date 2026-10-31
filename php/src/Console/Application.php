<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Cloudflare\Data\DnsRecord;
use Simtabi\VpsServerWorkbench\DigitalOcean\RunningAction;
use Simtabi\VpsServerWorkbench\Exception\ApiException;
use Simtabi\VpsServerWorkbench\Exception\ConfirmationRequiredException;
use Simtabi\VpsServerWorkbench\Exception\CredentialException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Exception\WorkbenchException;
use Simtabi\VpsServerWorkbench\Gcp\RunningOperation;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\Credentials;

/**
 * `bin/workbench do|cf|ploi|gcp|credentials ...`
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

    /** @param (\Closure(string): bool)|null $prompt Asks the user; default reads "yes" from a terminal. */
    public function __construct(?ProviderFactory $providers = null, ?Output $out = null, ?\Closure $prompt = null)
    {
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
            if ($input->flag('help') && $area !== 'help') {
                $this->out->line(Help::for($area));

                return self::OK;
            }

            return match ($area) {
                'do', 'digitalocean' => $this->digitalOcean($input),
                'cf', 'cloudflare' => $this->cloudflare($input),
                'ploi' => $this->ploi($input),
                'gcp', 'gcloud' => $this->gcp($input),
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
