<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

use Simtabi\VpsServerWorkbench\Exception\ActionFailedException;
use Simtabi\VpsServerWorkbench\Exception\ConfirmationRequiredException;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\Credentials;
use Simtabi\VpsServerWorkbench\Security\IssuedCredential;
use Simtabi\VpsServerWorkbench\Security\Secret;

/**
 * What every command shares: printing tables / one object / JSON, the single write path
 * (--dry-run, confirmation, --force for destructive), and the careful file handling for secrets.
 */
final readonly class Runner
{
    /**
     * @param \Closure(string): bool    $prompt
     * @param \Closure(): ?string       $stdin  reads piped stdin (null on a terminal or when empty)
     */
    public function __construct(private Output $out, private \Closure $prompt, private ?\Closure $stdin = null) {}

    public function out(): Output
    {
        return $this->out;
    }

    /**
     * The one path every write takes.
     *
     * @template T
     *
     * @param PendingAction<T> $action
     * @param \Closure(T): int $present
     */
    public function write(Input $in, PendingAction $action, \Closure $present): int
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

            return Application::OK;
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
    public function show(Input $in, array $items, array $columns): int
    {
        $rows = array_map(static fn (\JsonSerializable $item): array => self::row($item), $items);
        $in->flag('json') ? $this->out->json($rows) : $this->out->table($rows, $columns);

        return Application::OK;
    }

    /** @param \JsonSerializable|array<string, mixed> $item */
    public function showOne(Input $in, \JsonSerializable|array $item, ?string $message = null): int
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

        return Application::OK;
    }

    public function done(Input $in, bool $ok, string $message): int
    {
        $in->flag('json') ? $this->out->json(['ok' => $ok, 'message' => $message]) : $this->out->line($ok ? $message : 'failed: '.$message);

        return $ok ? Application::OK : Application::FAILED;
    }

    public function usage(string $area): int
    {
        $this->out->line(Help::for($area));

        return Application::USAGE;
    }

    public function printScript(Input $in, string $script): int
    {
        $in->flag('json') ? $this->out->json(['deployScript' => $script]) : $this->out->line(rtrim($script));

        return Application::OK;
    }

    public function readFile(?string $file): ?string
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

    /**
     * A secret value from --value-file or piped stdin; never from argv (shell history, `ps`).
     * One trailing newline is dropped (echo / heredocs add it).
     */
    public function readSecret(Input $in): Secret
    {
        $file = $in->value('value-file');
        $value = $file !== null ? $this->readFile($file) : ($this->stdin === null ? self::pipedStdin() : ($this->stdin)());
        $value = $value === null ? '' : (preg_replace('/\r?\n\z/', '', $value) ?? $value);
        if ($value === '') {
            throw new ValidationException('give the secret with --value-file <file> or pipe it on stdin (never as an argument)');
        }

        return new Secret($value);
    }

    /**
     * Where a one-time secret goes: --out must be a new file, outside any git checkout. Checked BEFORE
     * the write is sent, so a bad path never costs a secret that cannot be fetched again.
     */
    public function outPath(Input $in, string $what): string
    {
        $path = $in->value('out') ?? throw new ValidationException("--out <file> is required: the {$what} is shown only once and is written there (chmod 600), never printed");
        if (file_exists($path)) {
            throw new ValidationException(sprintf('%s already exists; pick a new file (nothing is overwritten)', $path));
        }
        if (! is_dir(dirname($path)) || ! is_writable(dirname($path))) {
            throw new ValidationException(sprintf('cannot write into %s', dirname($path)));
        }
        if (($repo = Credentials::enclosingRepository($path)) !== null) {
            throw new ValidationException(sprintf('%s is inside the git checkout %s; keep secrets outside repositories', $path, $repo));
        }

        return $path;
    }

    /**
     * Write a secret to a new 0600 file (created exclusively, so a racing file is never clobbered). If the
     * checked path was taken in the meantime, a sibling with a random suffix is used instead: the secret
     * has already been issued and cannot be fetched again. Returns the path actually written.
     */
    public function writePrivateFile(string $path, #[\SensitiveParameter] Secret $content): string
    {
        $old = umask(0o077);
        try {
            $handle = @fopen($path, 'x');
            if ($handle === false) {
                $path .= '.'.bin2hex(random_bytes(4));
                $handle = @fopen($path, 'x');
            }
            if ($handle === false) {
                throw new ActionFailedException(sprintf('could not create %s; the secret was issued but not saved, so revoke it and try again', $path));
            }
            fwrite($handle, $content->reveal());
            fclose($handle);
            chmod($path, 0o600);
        } finally {
            umask($old);
        }

        return $path;
    }

    /** Save the one-time secret, then show only the public half. */
    public function issued(Input $in, IssuedCredential $issued, string $path, string $message): int
    {
        $path = $this->writePrivateFile($path, $issued->secret);

        return $this->showOne($in, $issued->item->data + ['secretFile' => $path], $message." (secret written to {$path}, chmod 600)");
    }

    /** @return array<string, mixed> */
    public static function row(\JsonSerializable $item): array
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

    private static function pipedStdin(): ?string
    {
        if (stream_isatty(STDIN)) {
            return null;
        }
        $value = stream_get_contents(STDIN, 65_537);

        return is_string($value) && strlen($value) <= 65_536 ? $value : throw new ValidationException('stdin is larger than 64 KiB');
    }
}
