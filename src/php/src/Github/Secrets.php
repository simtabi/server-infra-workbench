<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Github;

use Simtabi\ServerInfraWorkbench\Exception\ActionFailedException;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Security\Secret;
use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\Item;

/**
 * Actions secrets (repository or environment). Values are encrypted HERE with the repository's public
 * key (libsodium sealed box, as GitHub requires); only the ciphertext leaves the machine, and only names
 * and dates can ever be read back.
 */
final readonly class Secrets
{
    private Endpoint $api;

    private string $base;

    public function __construct(private Transport $transport, private Repository $repo, private ?string $environment = null)
    {
        $this->base = $environment === null ? $repo->path('actions', 'secrets') : $repo->path('environments', self::environment($environment), 'secrets');
        $this->api = new Endpoint($transport, 'secret', $this->base, new GithubPaginator('secrets'),
            ['name' => 'name', 'createdAt' => 'created_at', 'updatedAt' => 'updated_at'], null, ['per_page' => 100]);
    }

    /** @return list<Item> names and dates only (GitHub never returns values) */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * Create or replace. The plan shows the name, never the value.
     *
     * @return PendingAction<bool>
     */
    public function set(string $name, #[\SensitiveParameter] Secret $value): PendingAction
    {
        $name = self::name($name);
        if ($value->reveal() === '') {
            throw new ValidationException('the secret value is empty');
        }
        if (strlen($value->reveal()) > 48 * 1024) {
            throw new ValidationException('GitHub secrets are limited to 48 KB');
        }
        self::requireSodium();
        $path = $this->base.'/'.$name;
        $scope = $this->environment === null ? (string) $this->repo : "{$this->repo} environment {$this->environment}";

        return $this->transport->pending('set secret', "{$name} in {$scope}", 'PUT', $path, ['encrypted_value' => '(sealed locally at confirm)', 'key_id' => '(repository public key)'],
            function () use ($path, $value): bool {
                $key = $this->transport->get($this->base.'/public-key')->json;

                return $this->transport->send('PUT', $path, [], [
                    'encrypted_value' => self::seal($value, Data::string($key, 'key')),
                    'key_id' => Data::string($key, 'key_id'),
                ])->status < 300;
            }, note: 'workflows see the new value on their next run');
    }

    /**
     * Destructive: workflows that use it start failing.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $name): PendingAction
    {
        return $this->api->delete(self::name($name), "{$name} in {$this->repo}", 'workflows using it get an empty value');
    }

    /** libsodium sealed box against GitHub's base64 Curve25519 public key, base64 out. */
    public static function seal(#[\SensitiveParameter] Secret $value, string $publicKeyBase64): string
    {
        self::requireSodium();
        $key = base64_decode($publicKeyBase64, true);
        if ($key === false || strlen($key) !== SODIUM_CRYPTO_BOX_PUBLICKEYBYTES) {
            throw new ActionFailedException('GitHub returned an invalid repository public key');
        }

        return base64_encode(sodium_crypto_box_seal($value->reveal(), $key));
    }

    public static function name(string $name): string
    {
        if (preg_match('/^[A-Za-z_][A-Za-z0-9_]{0,199}$/', $name) !== 1 || str_starts_with(strtoupper($name), 'GITHUB_')) {
            throw new ValidationException(sprintf('secret name "%s" must be letters, digits and _, not start with a digit or GITHUB_', substr($name, 0, 80)));
        }

        return $name;
    }

    private static function environment(string $environment): string
    {
        if (preg_match('/^[A-Za-z0-9._ -]{1,255}$/', $environment) !== 1) {
            throw new ValidationException(sprintf('environment "%s" is not a valid name', substr($environment, 0, 80)));
        }

        return rawurlencode($environment);
    }

    private static function requireSodium(): void
    {
        if (! function_exists('sodium_crypto_box_seal')) {
            throw new ActionFailedException('the sodium PHP extension is required to encrypt GitHub secrets (it ships with PHP; enable ext-sodium)');
        }
    }
}
