<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Security;

use Simtabi\ServerInfraWorkbench\Support\Item;

/**
 * A credential a provider shows exactly once (a Spaces secret key). The public part is an Item that is
 * safe to print; the secret stays a Secret so it can only be written to a 0600 file, never echoed.
 */
final readonly class IssuedCredential implements \JsonSerializable
{
    public function __construct(public Item $item, public Secret $secret) {}

    /** @return array<string, mixed> */
    public function jsonSerialize(): array
    {
        return $this->item->data;
    }
}
