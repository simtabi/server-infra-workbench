<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

use Psr\Http\Message\RequestInterface;
use Simtabi\VpsServerWorkbench\Http\Authenticator;
use Simtabi\VpsServerWorkbench\Security\Secret;

/** A token in any header ("Authorization: Bearer x", "X-Auth-Token: x", ...), plus fixed extra headers. */
final readonly class HeaderToken implements Authenticator
{
    /** @param array<string, string> $extra */
    public function __construct(private Secret $token, private string $header = 'Authorization', private string $prefix = 'Bearer ', private array $extra = []) {}

    public function authorize(RequestInterface $request, bool $write): RequestInterface
    {
        foreach ($this->extra as $name => $value) {
            $request = $request->withHeader($name, $value);
        }

        return $request->withHeader($this->header, $this->prefix.$this->token->reveal());
    }

    public function secrets(): array
    {
        return [$this->token->reveal()];
    }
}
