<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp\Auth;

use Simtabi\ServerInfraWorkbench\Exception\ApiException;
use Simtabi\ServerInfraWorkbench\Exception\AuthenticationException;
use Simtabi\ServerInfraWorkbench\Exception\CredentialException;
use Simtabi\ServerInfraWorkbench\Exception\TransportException;
use Simtabi\ServerInfraWorkbench\Http\ApiResponse;
use Simtabi\ServerInfraWorkbench\Http\ClientOptions;
use Simtabi\ServerInfraWorkbench\Security\Credentials;
use Simtabi\ServerInfraWorkbench\Security\Redactor;
use Simtabi\ServerInfraWorkbench\Security\Secret;
use Simtabi\ServerInfraWorkbench\Support\Data;

/**
 * OAuth 2.0 for service accounts (RFC 7523 JWT bearer grant, RS256), one token per scope, cached
 * until a minute before expiry. Reads use the compute.readonly scope; writes ask for compute.
 */
final class ServiceAccountTokenProvider implements TokenProvider
{
    private const string GRANT = 'urn:ietf:params:oauth:grant-type:jwt-bearer';

    /** @var array<string, array{0: Secret, 1: int}> */
    private array $cache = [];

    /** @var \Closure(): int */
    private readonly \Closure $clock;

    public function __construct(
        private readonly string $clientEmail,
        private readonly Secret $privateKey,
        private readonly ClientOptions $options,
        private readonly string $tokenUri = 'https://oauth2.googleapis.com/token',
        private readonly ?string $projectId = null,
        ?\Closure $clock = null,
    ) {
        $this->clock = $clock ?? static fn (): int => time();
        if (filter_var($clientEmail, FILTER_VALIDATE_EMAIL) === false) {
            throw new CredentialException('service account client_email is missing or invalid');
        }
        if (! str_starts_with($tokenUri, 'https://')) {
            throw new CredentialException('service account token_uri must be https');
        }
    }

    public static function fromFile(string $path, ClientOptions $options): self
    {
        if (! is_file($path) || ! is_readable($path)) {
            throw new CredentialException(sprintf('service account key %s does not exist or is not readable', $path));
        }
        $repo = Credentials::enclosingRepository($path);
        if ($repo !== null) {
            throw new CredentialException(sprintf('refusing to use service account key %s: it is inside the git working tree %s', $path, $repo));
        }
        $perms = fileperms($path);
        if ($perms !== false && ($perms & 0o077) !== 0) {
            throw new CredentialException(sprintf('service account key %s is mode %o; run: chmod 600 %s', $path, $perms & 0o777, escapeshellarg($path)));
        }

        try {
            $json = json_decode((string) file_get_contents($path), true, 16, JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            throw new CredentialException(sprintf('service account key %s is not valid JSON', $path));
        }

        return self::fromArray(is_array($json) ? $json : [], $options);
    }

    /** @param array<mixed> $key A decoded service-account JSON key. */
    public static function fromArray(array $key, ClientOptions $options): self
    {
        if (Data::string($key, 'type') !== 'service_account' || Data::string($key, 'private_key') === '') {
            throw new CredentialException('not a service account key (expected "type": "service_account" with a private_key)');
        }

        return new self(
            Data::string($key, 'client_email'),
            new Secret(Data::string($key, 'private_key')),
            $options,
            Data::string($key, 'token_uri', 'https://oauth2.googleapis.com/token'),
            Data::nullableString($key, 'project_id'),
        );
    }

    public function projectId(): ?string
    {
        return $this->projectId;
    }

    public function token(string $scope): Secret
    {
        $now = $this->now();
        if (isset($this->cache[$scope]) && $this->cache[$scope][1] - 60 > $now) {
            return $this->cache[$scope][0];
        }

        $request = $this->options->requestFactory()->createRequest('POST', $this->tokenUri)
            ->withHeader('Content-Type', 'application/x-www-form-urlencoded')
            ->withHeader('Accept', 'application/json')
            ->withBody($this->options->streamFactory()->createStream(http_build_query([
                'grant_type' => self::GRANT,
                'assertion' => $this->assertion($scope, $now),
            ])));

        try {
            $response = ApiResponse::from($this->options->httpClient()->sendRequest($request));
        } catch (\Psr\Http\Client\ClientExceptionInterface $e) {
            throw new TransportException('Google OAuth token request failed: '.(new Redactor)->redact($e->getMessage()));
        }
        $token = Data::string($response->json, 'access_token');
        if ($response->status !== 200 || $token === '') {
            throw new AuthenticationException(
                sprintf('Google OAuth token request failed: HTTP %d — %s', $response->status, (new Redactor)->redact(ApiException::detail($response->json) !== '' ? ApiException::detail($response->json) : Data::string($response->json, 'error'))),
                'Google Cloud',
                $response->status === 200 ? 401 : $response->status,
            );
        }
        $secret = new Secret($token);
        $this->cache[$scope] = [$secret, $now + Data::int($response->json, 'expires_in', 3600)];

        return $secret;
    }

    public function secrets(): array
    {
        return array_values(array_map(static fn (array $entry): string => $entry[0]->reveal(), $this->cache));
    }

    private function now(): int
    {
        $now = ($this->clock)();

        return is_int($now) ? $now : time();
    }

    private function assertion(string $scope, int $now): string
    {
        $segments = [
            self::b64(self::json(['alg' => 'RS256', 'typ' => 'JWT'])),
            self::b64(self::json([
                'iss' => $this->clientEmail,
                'scope' => $scope,
                'aud' => $this->tokenUri,
                'iat' => $now,
                'exp' => $now + 3600,
            ])),
        ];
        $key = openssl_pkey_get_private($this->privateKey->reveal());
        if ($key === false || ! openssl_sign(implode('.', $segments), $signature, $key, OPENSSL_ALGO_SHA256)) {
            throw new CredentialException('could not sign the OAuth assertion with the service account private key');
        }
        $segments[] = self::b64(is_string($signature) ? $signature : '');

        return implode('.', $segments);
    }

    /** @param array<string, int|string> $data */
    private static function json(array $data): string
    {
        return json_encode($data, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
    }

    private static function b64(string $data): string
    {
        return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
    }
}
