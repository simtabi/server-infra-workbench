<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

use Psr\Http\Message\RequestInterface;
use Simtabi\VpsServerWorkbench\Security\Secret;

final class BearerToken implements Authenticator
{
    public function __construct(private readonly Secret $token) {}

    public function authorize(RequestInterface $request, bool $write): RequestInterface
    {
        return $request->withHeader('Authorization', 'Bearer '.$this->token->reveal());
    }

    public function secrets(): array
    {
        return [$this->token->reveal()];
    }
}
