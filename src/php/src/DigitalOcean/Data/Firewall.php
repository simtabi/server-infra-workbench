<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean\Data;

use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\ExportsProperties;

final readonly class Firewall implements \JsonSerializable
{
    use ExportsProperties;

    /**
     * @param list<array<string, mixed>> $inboundRules
     * @param list<array<string, mixed>> $outboundRules
     * @param list<int>                  $dropletIds
     * @param list<string>               $tags
     */
    public function __construct(
        public string $id,
        public string $name,
        public string $status,
        public array $inboundRules,
        public array $outboundRules,
        public array $dropletIds,
        public array $tags,
        public bool $openToWorld,
    ) {}

    /** @param array<string, mixed> $d */
    public static function fromArray(array $d): self
    {
        $inbound = Data::objects($d, 'inbound_rules');
        $ids = [];
        $raw = Data::get($d, 'droplet_ids');
        foreach (is_array($raw) ? $raw : [] as $id) {
            if (is_int($id)) {
                $ids[] = $id;
            }
        }
        $world = false;
        foreach ($inbound as $rule) {
            $addresses = Data::strings($rule, 'sources.addresses');
            $ports = Data::string($rule, 'ports');
            if ((in_array('0.0.0.0/0', $addresses, true) || in_array('::/0', $addresses, true)) && ! in_array($ports, ['22', '80', '443'], true)) {
                $world = true;
            }
        }

        return new self(
            Data::string($d, 'id'),
            Data::string($d, 'name'),
            Data::string($d, 'status'),
            $inbound,
            Data::objects($d, 'outbound_rules'),
            $ids,
            Data::strings($d, 'tags'),
            $world,
        );
    }
}
