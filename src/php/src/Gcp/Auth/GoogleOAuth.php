<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp\Auth;

use Psr\Http\Message\RequestInterface;
use Simtabi\VpsServerWorkbench\Http\Authenticator;

/** Least privilege: reads ask for compute.readonly, only writes ask for compute. */
final readonly class GoogleOAuth implements Authenticator
{
    public const string SCOPE_READ = 'https://www.googleapis.com/auth/compute.readonly';

    public const string SCOPE_WRITE = 'https://www.googleapis.com/auth/compute';

    public function __construct(private TokenProvider $tokens) {}

    public function authorize(RequestInterface $request, bool $write): RequestInterface
    {
        return $request->withHeader('Authorization', 'Bearer '.$this->tokens->token($write ? self::SCOPE_WRITE : self::SCOPE_READ)->reveal());
    }

    public function secrets(): array
    {
        return $this->tokens->secrets();
    }
}
