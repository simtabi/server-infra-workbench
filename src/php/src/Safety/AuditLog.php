<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Safety;

/** Every planned, confirmed, succeeded or failed write is recorded here. Entries are pre-redacted. */
interface AuditLog
{
    public function record(AuditEntry $entry): void;
}
