<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Safety;

/**
 * Append-only JSON lines, one per event. The directory is 0700 and the file 0600.
 * Default: $VSW_AUDIT_LOG, else ~/.local/state/vps-server-workbench/audit.log.
 */
final class JsonlAuditLog implements AuditLog
{
    public const string PATH_ENV = 'VSW_AUDIT_LOG';

    public function __construct(private readonly string $path) {}

    public static function default(): AuditLog
    {
        $path = getenv(self::PATH_ENV);
        if (is_string($path) && $path !== '') {
            return $path === 'off' ? new NullAuditLog : new self($path);
        }
        $home = getenv('HOME');

        return is_string($home) && $home !== '' ? new self($home.'/.local/state/vps-server-workbench/audit.log') : new NullAuditLog;
    }

    public function path(): string
    {
        return $this->path;
    }

    public function record(AuditEntry $entry): void
    {
        $dir = dirname($this->path);
        if (! is_dir($dir) && ! @mkdir($dir, 0o700, true) && ! is_dir($dir)) {
            throw new \RuntimeException(sprintf('cannot create audit log directory %s', $dir));
        }
        $old = umask(0o077);

        try {
            $line = json_encode($entry, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES)."\n";
            if (@file_put_contents($this->path, $line, FILE_APPEND | LOCK_EX) === false) {
                throw new \RuntimeException(sprintf('cannot write audit log %s', $this->path));
            }
            @chmod($this->path, 0o600);
        } finally {
            umask($old);
        }
    }
}
