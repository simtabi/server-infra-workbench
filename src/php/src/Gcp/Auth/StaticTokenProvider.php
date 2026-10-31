<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp\Auth;

use Simtabi\VpsServerWorkbench\Security\Secret;

/** A token you already have (CI, workload identity, tests). */
final readonly class StaticTokenProvider implements TokenProvider
{
    private Secret $token;

    public function __construct(#[\SensitiveParameter] Secret|string $token)
    {
        $this->token = $token instanceof Secret ? $token : new Secret($token);
    }

    public function token(string $scope): Secret
    {
        return $this->token;
    }

    public function secrets(): array
    {
        return [$this->token->reveal()];
    }
}
