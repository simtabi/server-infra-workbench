<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Github;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;

/** owner/name, validated once so every path built from it is safe. */
final readonly class Repository implements \Stringable
{
    private function __construct(public string $owner, public string $name) {}

    public static function parse(string $value): self
    {
        if (preg_match('#^([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/([A-Za-z0-9._-]{1,100})$#', $value, $m) !== 1 || $m[2] === '.' || $m[2] === '..') {
            throw new ValidationException(sprintf('"%s" is not owner/repository', substr($value, 0, 140)));
        }

        return new self($m[1], $m[2]);
    }

    public function path(string ...$segments): string
    {
        return implode('/', ["/repos/{$this->owner}/{$this->name}", ...$segments]);
    }

    public function __toString(): string
    {
        return "{$this->owner}/{$this->name}";
    }
}
