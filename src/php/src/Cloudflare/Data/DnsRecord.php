<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Cloudflare\Data;

use Simtabi\ServerInfraWorkbench\Support\Data;
use Simtabi\ServerInfraWorkbench\Support\ExportsProperties;

final readonly class DnsRecord implements \JsonSerializable
{
    use ExportsProperties;

    public function __construct(
        public string $id,
        public DnsRecordType $type,
        public string $name,
        public string $content,
        public int $ttl,
        public bool $proxied,
        public ?int $priority = null,
        public ?string $comment = null,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $priority = Data::get($d, 'priority');

        return new self(
            Data::string($d, 'id'),
            DnsRecordType::tryFrom(Data::string($d, 'type')) ?? DnsRecordType::TXT,
            Data::string($d, 'name'),
            Data::string($d, 'content'),
            Data::int($d, 'ttl', 1),
            Data::bool($d, 'proxied'),
            is_int($priority) ? $priority : null,
            Data::nullableString($d, 'comment'),
        );
    }

    /** Same visible state as a desired record (ignores id/comment). */
    public function matches(DnsRecordType $type, string $name, string $content, int $ttl, bool $proxied, ?int $priority): bool
    {
        return $this->type === $type
            && strcasecmp($this->name, $name) === 0
            && $this->content === $content
            && ($proxied ? true : $this->ttl === $ttl)
            && $this->proxied === $proxied
            && ($priority === null || $this->priority === $priority);
    }
}
