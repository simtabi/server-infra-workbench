<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Security;

/**
 * A credential that cannot leak by accident: it prints, dumps, var_exports and json-encodes as "***".
 * The only way to the value is reveal(), which the transport calls when it builds a request header.
 */
final class Secret implements \JsonSerializable, \Stringable
{
    public function __construct(#[\SensitiveParameter] private readonly string $value)
    {
        if ($value === '') {
            throw new \LogicException('a secret cannot be empty');
        }
    }

    public function __toString(): string
    {
        return '***';
    }

    /** @return array{value: string} */
    public function __debugInfo(): array
    {
        return ['value' => '***'];
    }

    /** @return array<never> */
    public function __serialize(): array
    {
        throw new \LogicException('secrets cannot be serialized');
    }

    public function reveal(): string
    {
        return $this->value;
    }

    public function jsonSerialize(): string
    {
        return '***';
    }

    public function equals(self $other): bool
    {
        return hash_equals($this->value, $other->value);
    }
}
