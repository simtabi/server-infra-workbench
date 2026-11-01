<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Http;

use Psr\Http\Message\RequestInterface;

interface Authenticator
{
    /** @param bool $write Lets OAuth providers ask for a narrower read-only scope on reads. */
    public function authorize(RequestInterface $request, bool $write): RequestInterface;

    /**
     * Values the redactor must mask (tokens issued so far).
     *
     * @return list<string>
     */
    public function secrets(): array;
}
