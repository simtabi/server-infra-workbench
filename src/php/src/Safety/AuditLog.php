<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Safety;

/** Every planned, confirmed, succeeded or failed write is recorded here. Entries are pre-redacted. */
interface AuditLog
{
    public function record(AuditEntry $entry): void;
}
