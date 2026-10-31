<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp\Auth;

use Simtabi\VpsServerWorkbench\Security\Secret;

interface TokenProvider
{
    /** An OAuth access token valid for at least a minute, for the given scope. */
    public function token(string $scope): Secret;

    /**
     * Tokens issued so far, for redaction.
     *
     * @return list<string>
     */
    public function secrets(): array;
}
