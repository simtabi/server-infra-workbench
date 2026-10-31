<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

use Simtabi\VpsServerWorkbench\Exception\ConfirmationRequiredException;
use Simtabi\VpsServerWorkbench\Exception\TransportException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Safety\AuditLog;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\Redactor;

/**
 * ~/.ssh/authorized_keys on a running server, over ssh. Because this file decides who can log in:
 *
 *  - the key your current session logged in with can never be removed (read from `ssh -v`);
 *  - removing the last key, one of your own local keys, or any key when the session key is unknown, needs --force;
 *    (not flagged destructive: the change is backed up and rolled back automatically if a fresh login fails)
 *  - every write backs the file up (authorized_keys.bak.TIMESTAMP), writes atomically (temp + rename),
 *    sets 700/600, reads the file back to validate it, then tests a FRESH login while the first
 *    connection is held open (ssh ControlMaster); if the fresh login fails the backup is restored
 *    through the held connection.
 */
final class ServerKeys
{
    private const string FILE = '~/.ssh/authorized_keys';

    /** @var list<string> */
    private array $master;

    private ?string $sessionFingerprint = null;

    private bool $probed = false;

    /**
     * @param list<string> $sshOptions extra ssh flags, e.g. ['-p', '2222', '-i', '~/.ssh/deploy']
     * @param list<string> $localPublicKeys your own public key lines (warned about before removal)
     */
    public function __construct(
        private readonly SshRunner $ssh,
        private readonly string $target,
        private readonly array $sshOptions,
        private readonly AuditLog $audit,
        private readonly array $localPublicKeys = [],
        ?string $controlDir = null,
    ) {
        if (preg_match('/^(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9._:-]+$/', $target) !== 1 || str_starts_with($target, '-')) {
            throw new ValidationException(sprintf('host "%s" must be user@host or an ssh config alias', $target));
        }
        $dir = $controlDir ?? sys_get_temp_dir();
        $this->master = ['-o', 'ControlMaster=auto', '-o', 'ControlPath='.$dir.'/vsw-cm-%C', '-o', 'ControlPersist=120'];
    }

    public function target(): string
    {
        return $this->target;
    }

    public function read(): string
    {
        return $this->exec('cat '.self::FILE.' 2>/dev/null || true')['stdout'];
    }

    /** @return list<array{line: string, key: PublicKey}> */
    public function entries(): array
    {
        return AuthorizedKeys::entries($this->read());
    }

    /** SHA256 fingerprint of the key the current ssh session authenticates with, if ssh reports it. */
    public function sessionFingerprint(): ?string
    {
        if (! $this->probed) {
            $this->probed = true;
            $r = $this->ssh->run($this->target, [...$this->sshOptions, '-o', 'ControlPath=none', '-v'], 'true');
            if (preg_match_all('/Server accepts key: .*?(SHA256:[A-Za-z0-9+\/]+)/', $r['stderr'], $m) > 0) {
                $last = end($m[1]);
                $this->sessionFingerprint = $last === false ? null : $last;
            }
        }

        return $this->sessionFingerprint;
    }

    /** @return PendingAction<string> the backup file name, or '' for a no-op */
    public function add(string $publicKey): PendingAction
    {
        $key = PublicKey::parse($publicKey);
        $text = $this->read();
        [$new, $added] = AuthorizedKeys::add($text, $key->line());
        if (! $added) {
            return $this->pending('add authorized key', "{$key->label()} ({$key->fingerprint()}) already present", 'NONE', [], static fn (): string => '');
        }

        return $this->pending('add authorized key', "{$key->label()} ({$key->fingerprint()})", 'SSH',
            ['add' => $key->fingerprint(), 'keysAfter' => AuthorizedKeys::count($new)],
            fn (): string => $this->write($text, $new));
    }

    /**
     * @param string $selector 1-based number (as in list), SHA256 fingerprint, or the key's comment
     * @return PendingAction<string>
     */
    public function remove(string $selector, bool $force = false): PendingAction
    {
        $text = $this->read();
        $entry = AuthorizedKeys::select($text, $selector) ?? throw new ValidationException(sprintf('no single key matches "%s" (use the number from: workbench keys server list)', $selector));
        $key = $entry['key'];
        $session = $this->sessionFingerprint();
        if ($session !== null && $session === $key->fingerprint()) {
            throw new ValidationException("refusing: {$key->fingerprint()} is the key your current session logged in with. Log in with another key first, then remove this one.");
        }
        [$new, $removed] = AuthorizedKeys::remove($text, $key);
        if (! $force) {
            if ($session === null) {
                throw new ConfirmationRequiredException('could not tell which key this session uses (ssh -v did not say); re-run with --force if you are sure it is not '.$key->fingerprint());
            }
            if (AuthorizedKeys::count($new) === 0) {
                throw new ConfirmationRequiredException("this is the last key in {$this->target}:".self::FILE.'; key logins would stop working. Re-run with --force to leave it empty.');
            }
            foreach ($this->localPublicKeys as $local) {
                if (PublicKey::same($local, $key->line())) {
                    throw new ConfirmationRequiredException('this key matches one of your local ~/.ssh/*.pub keys; removing it may lock you out on your next login. Re-run with --force to remove it anyway.');
                }
            }
        }

        return $this->pending('remove authorized key', "{$key->label()} ({$key->fingerprint()})", 'SSH',
            ['remove' => $key->fingerprint(), 'lines' => $removed, 'keysAfter' => AuthorizedKeys::count($new)],
            fn (): string => $this->write($text, $new));
    }

    /** @return PendingAction<string> */
    public function fixPermissions(): PendingAction
    {
        return $this->pending('fix ~/.ssh permissions', '700 ~/.ssh, 600 authorized_keys', 'SSH', [], function (): string {
            $this->exec('set -e; mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch '.self::FILE.'; chmod 600 '.self::FILE.'; chmod go-w ~');

            return '';
        });
    }

    /** Backup, atomic write, read-back validation, fresh-login test, automatic restore on failure. */
    private function write(string $before, string $after): string
    {
        $backup = 'authorized_keys.bak.'.gmdate('Ymd-His');
        $script = implode('; ', [
            'set -e', 'umask 077', 'mkdir -p ~/.ssh', 'chmod 700 ~/.ssh', 'touch '.self::FILE,
            'cp -p '.self::FILE.' ~/.ssh/'.$backup,
            'cat > ~/.ssh/authorized_keys.new', 'chmod 600 ~/.ssh/authorized_keys.new',
            'mv ~/.ssh/authorized_keys.new '.self::FILE,
        ]);
        // hold a master connection open for the whole change
        $this->exec('true');
        if (sha1($this->read()) !== sha1($before)) {
            throw new TransportException("{$this->target}: authorized_keys changed while we were editing it; nothing written, run the command again");
        }
        $this->exec($script, $after);
        $readBack = $this->read();
        if ($readBack !== $after) {
            $this->exec('cp -p ~/.ssh/'.$backup.' '.self::FILE);

            throw new TransportException("{$this->target}: authorized_keys did not read back as written; restored ~/.ssh/{$backup}");
        }
        if (AuthorizedKeys::count($after) > 0) {
            $fresh = $this->ssh->run($this->target, [...$this->sshOptions, '-o', 'ControlPath=none'], 'true');
            if ($fresh['exit'] !== 0) {
                $this->exec('cp -p ~/.ssh/'.$backup.' '.self::FILE);

                throw new TransportException("{$this->target}: a fresh login failed after the change, so ~/.ssh/{$backup} was restored (nothing changed). ssh said: ".trim($fresh['stderr']));
            }
        }

        return $backup;
    }

    /** @return array{exit: int, stdout: string, stderr: string} */
    private function exec(string $command, ?string $stdin = null): array
    {
        $r = $this->ssh->run($this->target, [...$this->sshOptions, ...$this->master], $command, $stdin);
        if ($r['exit'] !== 0) {
            $detail = trim($r['stderr']) !== '' ? trim($r['stderr']) : (trim($r['stdout']) !== '' ? trim($r['stdout']) : 'no detail');

            throw new TransportException("ssh to {$this->target} failed: {$detail}");
        }

        return $r;
    }

    /**
     * @template T
     *
     * @param array<mixed>  $payload
     * @param \Closure(): T $run
     * @return PendingAction<T>
     */
    private function pending(string $action, string $what, string $method, array $payload, \Closure $run, bool $destructive = false): PendingAction
    {
        return new PendingAction('ssh', $action, "{$what} on {$this->target}", $method, self::FILE, $payload, $run, $this->audit, new Redactor, $destructive,
            $method === 'NONE' ? null : 'backs up the file first; keep this session open and test a new login before closing it');
    }

    /**
     * Your own public keys (~/.ssh/*.pub). Public halves only; private keys are never read.
     *
     * @return list<string>
     */
    public static function localPublicKeys(?string $home = null): array
    {
        $home ??= (string) getenv('HOME');
        $out = [];
        $files = glob($home.'/.ssh/*.pub');
        foreach ($files === false ? [] : $files as $file) {
            $line = trim((string) @file_get_contents($file));
            if (PublicKey::isValid($line)) {
                $out[] = $line;
            }
        }

        return $out;
    }
}
