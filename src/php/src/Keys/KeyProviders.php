<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\ClientOptions;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Security\Credentials;

/**
 * The account-key providers: DigitalOcean, Vultr, Hetzner Cloud, Linode, Scaleway, plus any described
 * in a keys.json file ({"extra_providers": [...]}, same schema as the old vpskeys config.json).
 * Built-ins win on a name clash, so a config entry can never shadow tested code.
 */
final class KeyProviders
{
    /** @var array<string, KeyApiSpec> */
    private array $specs;

    /** @param list<KeyApiSpec> $extra */
    public function __construct(array $extra = [])
    {
        $this->specs = self::builtins();
        foreach ($extra as $spec) {
            $this->specs[$spec->name] ??= $spec;
        }
    }

    /** @return array<string, KeyApiSpec> */
    public static function builtins(): array
    {
        return [
            'digitalocean' => new KeyApiSpec('digitalocean', 'https://api.digitalocean.com/v2', 'DIGITALOCEAN_TOKEN', '/account/keys', 'ssh_keys',
                fingerprintField: 'fingerprint', itemField: 'ssh_key', deletePath: '/account/keys/{id}', renamePath: '/account/keys/{id}', renameMethod: 'PUT', pagination: 'digitalocean'),
            'vultr' => new KeyApiSpec('vultr', 'https://api.vultr.com/v2', 'VULTR_API_KEY', '/ssh-keys', 'ssh_keys',
                publicKeyField: 'ssh_key', itemField: 'ssh_key', createKeyField: 'ssh_key', deletePath: '/ssh-keys/{id}', renamePath: '/ssh-keys/{id}', renameMethod: 'PATCH', pagination: 'cursor', pageSize: 500),
            'hetzner' => new KeyApiSpec('hetzner', 'https://api.hetzner.cloud/v1', 'HCLOUD_TOKEN', '/ssh_keys', 'ssh_keys',
                fingerprintField: 'fingerprint', itemField: 'ssh_key', deletePath: '/ssh_keys/{id}', renamePath: '/ssh_keys/{id}', renameMethod: 'PUT', pagination: 'hetzner', pageSize: 50),
            'linode' => new KeyApiSpec('linode', 'https://api.linode.com/v4', 'LINODE_TOKEN', '/profile/sshkeys', 'data',
                nameField: 'label', publicKeyField: 'ssh_key', createNameField: 'label', createKeyField: 'ssh_key', deletePath: '/profile/sshkeys/{id}',
                renamePath: '/profile/sshkeys/{id}', renameMethod: 'PUT', renameField: 'label', pagination: 'linode'),
            'scaleway' => new KeyApiSpec('scaleway', 'https://api.scaleway.com/iam/v1alpha1', 'SCW_SECRET_KEY', '/ssh-keys', 'ssh_keys',
                fingerprintField: 'fingerprint', deletePath: '/ssh-keys/{id}', renamePath: '/ssh-keys/{id}', renameMethod: 'PATCH',
                authHeaderName: 'X-Auth-Token', authHeaderPrefix: '', pagination: 'scaleway', scopeEnv: 'SCW_PROJECT_ID', scopeField: 'project_id'),
        ];
    }

    /**
     * Built-ins plus the extra providers in $file (or $VSW_KEYS_CONFIG, $VPSKEYS_CONFIG,
     * ~/.config/vps-server-workbench/keys.json). A missing file is fine; a broken one is an error.
     */
    public static function load(?string $file = null): self
    {
        $file ??= self::defaultConfig();
        if ($file === null || ! is_file($file)) {
            return new self;
        }
        try {
            $config = json_decode((string) file_get_contents($file), true, 32, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new ValidationException(sprintf("config file %s isn't valid JSON: %s", $file, $e->getMessage()));
        }
        $extra = [];
        $entries = is_array($config) && is_array($config['extra_providers'] ?? null) ? $config['extra_providers'] : [];
        foreach ($entries as $entry) {
            $extra[] = KeyApiSpec::fromConfig(is_array($entry) ? $entry : []);
        }

        return new self($extra);
    }

    public static function defaultConfig(): ?string
    {
        foreach (['VSW_KEYS_CONFIG', 'VPSKEYS_CONFIG'] as $env) {
            $value = getenv($env);
            if (is_string($value) && $value !== '') {
                return $value;
            }
        }
        $home = getenv('HOME');

        return is_string($home) && $home !== '' ? $home.'/.config/vps-server-workbench/keys.json' : null;
    }

    /** @return list<string> */
    public function names(): array
    {
        return array_keys($this->specs);
    }

    public function spec(string $name): KeyApiSpec
    {
        return $this->specs[$name] ?? throw new ValidationException(sprintf("unknown provider '%s'. Known providers: %s", $name, implode(', ', $this->sortedNames())));
    }

    /**
     * Providers whose credentials are present (env or credentials file).
     *
     * @return list<string>
     */
    public function available(Credentials $credentials): array
    {
        return array_values(array_filter($this->names(), function (string $name) use ($credentials): bool {
            $spec = $this->specs[$name];

            return $credentials->has($spec->tokenEnv) && ($spec->scopeEnv === '' || $credentials->has($spec->scopeEnv));
        }));
    }

    public function make(string $name, ClientOptions $options, ?Credentials $credentials = null): AccountKeys
    {
        $spec = $this->spec($name);
        $credentials ??= Credentials::fromEnvironment();
        $scope = null;
        if ($spec->scopeEnv !== '') {
            if (! $credentials->has($spec->scopeEnv)) {
                throw new \Simtabi\VpsServerWorkbench\Exception\CredentialException(sprintf('%s: also set %s (the project these keys belong to)', $name, $spec->scopeEnv));
            }
            $scope = $credentials->get($spec->scopeEnv)->reveal();
        }
        $auth = new HeaderToken($credentials->get($spec->tokenEnv), $spec->authHeaderName, $spec->authHeaderPrefix, $spec->extraHeaders);

        return new RestAccountKeys(new Transport(self::label($name), $spec->baseUrl, $auth, $options), $spec, $scope);
    }

    private static function label(string $name): string
    {
        return match ($name) {
            'digitalocean' => 'DigitalOcean', 'vultr' => 'Vultr', 'hetzner' => 'Hetzner', 'linode' => 'Linode', 'scaleway' => 'Scaleway',
            default => $name,
        };
    }

    /** @return list<string> */
    private function sortedNames(): array
    {
        $names = $this->names();
        sort($names);

        return $names;
    }
}
