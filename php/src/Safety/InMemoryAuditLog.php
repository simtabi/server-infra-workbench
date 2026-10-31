<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Safety;

final class InMemoryAuditLog implements AuditLog
{
    /** @var list<AuditEntry> */
    public array $entries = [];

    public function record(AuditEntry $entry): void
    {
        $this->entries[] = $entry;
    }

    /** @return list<string> */
    public function outcomes(): array
    {
        return array_map(static fn (AuditEntry $e): string => $e->outcome, $this->entries);
    }
}
