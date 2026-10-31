<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp\Data;

enum InstanceStatus: string
{
    case Provisioning = 'PROVISIONING';
    case Staging = 'STAGING';
    case Running = 'RUNNING';
    case Stopping = 'STOPPING';
    case Stopped = 'STOPPED';
    case Suspending = 'SUSPENDING';
    case Suspended = 'SUSPENDED';
    case Repairing = 'REPAIRING';
    case Terminated = 'TERMINATED';
    case Unknown = 'UNKNOWN';

    public static function parse(string $value): self
    {
        return self::tryFrom($value) ?? self::Unknown;
    }
}
