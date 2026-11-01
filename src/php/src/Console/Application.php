<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

use Simtabi\ServerInfraWorkbench\Console\Commands\CloudflareCommand;
use Simtabi\ServerInfraWorkbench\Console\Commands\DigitalOceanCommand;
use Simtabi\ServerInfraWorkbench\Console\Commands\GcpCommand;
use Simtabi\ServerInfraWorkbench\Console\Commands\GithubCommand;
use Simtabi\ServerInfraWorkbench\Console\Commands\PloiCommand;
use Simtabi\ServerInfraWorkbench\Exception\ApiException;
use Simtabi\ServerInfraWorkbench\Exception\ConfirmationRequiredException;
use Simtabi\ServerInfraWorkbench\Exception\CredentialException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Exception\WorkbenchException;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Keys\PublicKey;
use Simtabi\ServerInfraWorkbench\Keys\SshKey;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Support\Env;

/**
 * `bin/workbench do|cf|gcp|github|ploi|keys|health|credentials ...`
 *
 * Provider areas live in Console\Commands (one class each); this class parses, dispatches and maps
 * exceptions to exit codes. Output, the write path and secret-file handling are in Runner.
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

    private readonly Runner $runner;

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
        $this->runner = new Runner($this->out, $this->prompt);
    }

    /** @param list<string> $argv */
    public function run(array $argv): int
    {
        try {
            foreach (Env::legacyInUse() as $legacy) {
                $this->out->error(sprintf('note: %s is deprecated, use %s%s (the old name is still read for now)', $legacy, Env::PREFIX, substr($legacy, strlen(Env::LEGACY_PREFIX))));
            }
            $area = $argv[0] ?? 'help';
            if (in_array($area, ['do', 'digitalocean'], true) && ($argv[1] ?? null) === 'ssh-keys') {
                // DigitalOcean account SSH keys are the keys module with --provider digitalocean (one implementation).
                [$area, $argv] = ['keys', ['keys', 'account', ...array_slice($argv, 2), '--provider', 'digitalocean']];
            }
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
                'do', 'digitalocean' => (new DigitalOceanCommand($this->providers, $this->runner))->run($input),
                'cf', 'cloudflare' => (new CloudflareCommand($this->providers, $this->runner))->run($input),
                'ploi' => (new PloiCommand($this->providers, $this->runner))->run($input),
                'gcp', 'gcloud' => (new GcpCommand($this->providers, $this->runner))->run($input),
                'github', 'gh' => (new GithubCommand($this->providers, $this->runner))->run($input),
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

    /** `workbench health <url>...`: exit 0 only when every endpoint passes. */
    private function health(Input $in): int
    {
        $urls = $in->args();
        if ($urls === []) {
            return $this->runner->usage('health');
        }
        $check = $this->providers->health();
        $results = array_map(fn (string $url) => $check->check($url, $in->int('expect', 200), $in->value('contains'), $in->value('max-ms') === null ? null : $in->int('max-ms', 0)), $urls);
        if ($in->flag('json')) {
            $this->out->json(array_map(Runner::row(...), $results));
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
            'fingerprint' => $this->runner->showOne($in, (static fn (PublicKey $k): array => ['type' => $k->type, 'comment' => $k->comment, 'sha256' => $k->fingerprint(), 'md5' => $k->md5()])(PublicKey::parse($this->publicKey($in)))),
            'help' => $this->runner->usage('keys'),
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
            'list', null => $this->runner->show($in, $keys()->list(), ['id' => 'ID', 'name' => 'NAME', 'fingerprint' => 'FINGERPRINT']),
            'add' => $this->runner->write($in, $keys()->add($in->value('name') ?? throw new ValidationException('--name is required'), $this->publicKey($in)),
                fn (SshKey $k): int => $this->runner->showOne($in, $k, 'key on the account')),
            'rename' => $this->runner->write($in, $keys()->rename($in->arg(2, 'key-id'), $in->value('name') ?? throw new ValidationException('--name is required')), fn (bool $ok): int => $this->runner->done($in, $ok, 'key renamed')),
            'remove', 'delete' => $this->runner->write($in, $keys()->remove($in->arg(2, 'key-id')), fn (bool $ok): int => $this->runner->done($in, $ok, 'key removed from the account (servers keep it)')),
            default => $this->runner->usage('keys'),
        };
    }

    private function serverKeys(Input $in): int
    {
        $server = fn () => $this->providers->serverKeys($in->value('host') ?? throw new ValidationException('--host user@host is required'), $this->sshOptions($in));

        return match ($in->optionalArg(1)) {
            'list', null => $this->serverKeyList($in, $server()),
            'add' => $this->runner->write($in, $server()->add($this->publicKey($in)), fn (string $backup): int => $this->runner->done($in, true, $backup === '' ? 'already there; nothing changed' : "key added (backup: ~/.ssh/{$backup}). Keep this session open and test a new login.")),
            'remove' => $this->runner->write($in, $server()->remove($in->arg(2, 'number|fingerprint|comment'), $in->flag('force')), fn (string $backup): int => $this->runner->done($in, true, "key removed (backup: ~/.ssh/{$backup}); a fresh login was tested")),
            'fix-perms', 'fix-permissions' => $this->runner->write($in, $server()->fixPermissions(), fn (string $unused): int => $this->runner->done($in, true, 'permissions fixed')),
            default => $this->runner->usage('keys'),
        };
    }

    private function serverKeyList(Input $in, \Simtabi\ServerInfraWorkbench\Keys\ServerKeys $server): int
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
                '1' => $this->out->table(array_map(Runner::row(...), $keys->list()), ['id' => 'ID', 'name' => 'NAME', 'fingerprint' => 'FINGERPRINT']),
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

    private function help(Input $in): int
    {
        $this->out->line(Help::for($in->optionalArg(0) ?? 'main'));

        return self::OK;
    }

    private function version(): int
    {
        $this->out->line('server-infra-workbench '.ClientOptions::VERSION.' (PHP '.PHP_VERSION.')');

        return self::OK;
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
