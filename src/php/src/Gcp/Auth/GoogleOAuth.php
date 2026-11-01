<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Gcp\Auth;

use Psr\Http\Message\RequestInterface;
use Simtabi\ServerInfraWorkbench\Http\Authenticator;

/**
 * Least privilege: each API gets its own scopes, and reads ask for the read-only one. A key that is only
 * ever used to list instances never holds a token that could change Cloud DNS or delete a bucket.
 */
final readonly class GoogleOAuth implements Authenticator
{
    public const string SCOPE_READ = 'https://www.googleapis.com/auth/compute.readonly';

    public const string SCOPE_WRITE = 'https://www.googleapis.com/auth/compute';

    public const string DNS_READ = 'https://www.googleapis.com/auth/ndev.clouddns.readonly';

    public const string DNS_WRITE = 'https://www.googleapis.com/auth/ndev.clouddns.readwrite';

    public const string STORAGE_READ = 'https://www.googleapis.com/auth/devstorage.read_only';

    public const string STORAGE_WRITE = 'https://www.googleapis.com/auth/devstorage.read_write';

    public function __construct(private TokenProvider $tokens, private string $readScope = self::SCOPE_READ, private string $writeScope = self::SCOPE_WRITE) {}

    public static function compute(TokenProvider $tokens): self
    {
        return new self($tokens);
    }

    public static function dns(TokenProvider $tokens): self
    {
        return new self($tokens, self::DNS_READ, self::DNS_WRITE);
    }

    public static function storage(TokenProvider $tokens): self
    {
        return new self($tokens, self::STORAGE_READ, self::STORAGE_WRITE);
    }

    public function authorize(RequestInterface $request, bool $write): RequestInterface
    {
        return $request->withHeader('Authorization', 'Bearer '.$this->tokens->token($write ? $this->writeScope : $this->readScope)->reveal());
    }

    public function secrets(): array
    {
        return $this->tokens->secrets();
    }
}
