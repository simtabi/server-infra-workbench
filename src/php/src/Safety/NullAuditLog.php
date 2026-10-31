<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Safety;

final class NullAuditLog implements AuditLog
{
    public function record(AuditEntry $entry): void {}
}
