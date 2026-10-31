<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Security;

use Simtabi\VpsServerWorkbench\Exception\CredentialException;

/**
 * Where credentials come from, in order: an explicit value, an environment variable, then a
 * KEY=VALUE file (default ~/.config/vps-server-workbench/credentials, or $VSW_CREDENTIALS_FILE).
 * The file must be owned by you, mode 0600 (no group/other bits) and must not sit inside a git
 * working tree. Values are never logged; errors name the key and the places looked, never the value.
 */
final class Credentials
{
    public const string FILE_ENV = 'VSW_CREDENTIALS_FILE';

    /** Every key the workbench understands, with what it is for. */
    public const array KEYS = [
        'DIGITALOCEAN_TOKEN' => 'DigitalOcean personal access token',
        'PLOI_API_TOKEN' => 'Ploi API token',
        'CLOUDFLARE_API_TOKEN' => 'Cloudflare API token (scoped)',
        'GOOGLE_APPLICATION_CREDENTIALS' => 'Path to a Google service-account JSON key',
        'GCP_PROJECT' => 'Google Cloud project id',
        'VULTR_API_KEY' => 'Vultr API key (workbench keys --provider vultr)',
        'HCLOUD_TOKEN' => 'Hetzner Cloud API token (workbench keys --provider hetzner)',
        'LINODE_TOKEN' => 'Linode / Akamai personal access token (workbench keys --provider linode)',
        'SCW_SECRET_KEY' => 'Scaleway secret key (workbench keys --provider scaleway)',
        'SCW_PROJECT_ID' => 'Scaleway project id the keys belong to',
    ];

    /** @var array<string, string>|null */
    private ?array $fileValues = null;

    /** @param array<string, string>|null $env Injected environment (tests); null reads getenv(). */
    public function __construct(private readonly ?string $file = null, private readonly ?array $env = null) {}

    public static function fromEnvironment(): self
    {
        return new self(self::defaultFile());
    }

    public static function defaultFile(): ?string
    {
        $file = getenv(self::FILE_ENV);
        if (is_string($file) && $file !== '') {
            return $file;
        }
        $home = getenv('HOME');

        return is_string($home) && $home !== '' ? $home.'/.config/vps-server-workbench/credentials' : null;
    }

    /** Resolve a credential: an explicit value wins, otherwise look the key up. */
    public static function resolve(Secret|string|null $explicit, string $key, ?self $store = null): Secret
    {
        if ($explicit instanceof Secret) {
            return $explicit;
        }
        if (is_string($explicit) && $explicit !== '') {
            return new Secret($explicit);
        }

        return ($store ?? self::fromEnvironment())->get($key);
    }

    public function has(string $key): bool
    {
        return $this->source($key) !== null;
    }

    /** "env", "file" or null. Never the value. */
    public function source(string $key): ?string
    {
        if ($this->fromEnv($key) !== null) {
            return 'env';
        }

        return isset($this->fileValues()[$key]) ? 'file' : null;
    }

    public function get(string $key): Secret
    {
        $value = $this->fromEnv($key) ?? $this->fileValues()[$key] ?? null;
        if ($value === null || $value === '') {
            throw new CredentialException(sprintf(
                '%s is not set. Export it, or put a %s line in %s (chmod 600, outside any git repo). Check with: bin/workbench credentials',
                $key,
                $key,
                $this->file ?? '~/.config/vps-server-workbench/credentials',
            ));
        }

        return new Secret($value);
    }

    public function file(): ?string
    {
        return $this->file;
    }

    /**
     * Problems with the credentials file, if it exists. Empty list = fine or absent.
     *
     * @return list<string>
     */
    public function fileProblems(): array
    {
        if ($this->file === null || ! file_exists($this->file)) {
            return [];
        }
        $problems = [];
        clearstatcache(true, $this->file);
        $perms = fileperms($this->file);
        if ($perms !== false && ($perms & 0o077) !== 0) {
            $problems[] = sprintf('%s is mode %o; run: chmod 600 %s', $this->file, $perms & 0o777, escapeshellarg($this->file));
        }
        if (function_exists('posix_geteuid')) {
            $owner = fileowner($this->file);
            if ($owner !== false && $owner !== posix_geteuid()) {
                $problems[] = sprintf('%s is not owned by the current user', $this->file);
            }
        }
        $repo = self::enclosingRepository($this->file);
        if ($repo !== null) {
            $problems[] = sprintf('%s is inside the git working tree %s; move it outside any repository', $this->file, $repo);
        }

        return $problems;
    }

    public static function enclosingRepository(string $path): ?string
    {
        $dir = realpath(dirname($path));
        while (is_string($dir) && $dir !== '' && $dir !== dirname($dir)) {
            if (file_exists($dir.'/.git')) {
                return $dir;
            }
            $dir = dirname($dir);
        }

        return null;
    }

    private function fromEnv(string $key): ?string
    {
        $value = $this->env !== null ? ($this->env[$key] ?? null) : getenv($key);

        return is_string($value) && $value !== '' ? $value : null;
    }

    /** @return array<string, string> */
    private function fileValues(): array
    {
        if ($this->fileValues !== null) {
            return $this->fileValues;
        }
        $this->fileValues = [];
        if ($this->file === null || ! is_file($this->file)) {
            return $this->fileValues;
        }
        $problems = $this->fileProblems();
        if ($problems !== []) {
            throw new CredentialException('refusing to read credentials file: '.implode('; ', $problems));
        }
        $lines = file($this->file, FILE_IGNORE_NEW_LINES);
        $lines = $lines === false ? [] : $lines;
        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '' || str_starts_with($line, '#')) {
                continue;
            }
            if (preg_match('/^(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*)$/', $line, $m) !== 1) {
                continue;
            }
            $value = $m[2];
            $quote = $value[0] ?? '';
            if (strlen($value) >= 2 && ($quote === '"' || $quote === "'") && str_ends_with($value, $quote)) {
                $value = substr($value, 1, -1);
            } else {
                $value = trim((string) preg_replace('/\s+#.*$/', '', $value));
            }
            $this->fileValues[$m[1]] = $value;
        }

        return $this->fileValues;
    }
}
