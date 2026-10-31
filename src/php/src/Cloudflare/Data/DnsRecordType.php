<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Cloudflare\Data;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;

enum DnsRecordType: string
{
    case A = 'A';
    case AAAA = 'AAAA';
    case CNAME = 'CNAME';
    case TXT = 'TXT';
    case MX = 'MX';
    case NS = 'NS';
    case CAA = 'CAA';
    case SRV = 'SRV';

    public static function parse(self|string $value): self
    {
        if ($value instanceof self) {
            return $value;
        }

        return self::tryFrom(strtoupper($value))
            ?? throw new ValidationException(sprintf('unknown DNS record type "%s" (use one of %s)', $value, implode(', ', array_column(self::cases(), 'value'))));
    }

    public function proxiable(): bool
    {
        return in_array($this, [self::A, self::AAAA, self::CNAME], true);
    }
}
