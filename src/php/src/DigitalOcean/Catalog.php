<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Support\Item;

/** What can be created where: regions and sizes (read-only). */
final readonly class Catalog
{
    public function __construct(private Transport $transport) {}

    /** @return list<Item> */
    public function regions(): array
    {
        return (new Endpoint($this->transport, 'region', '/v2/regions', new DigitalOceanPaginator('regions'),
            ['slug' => 'slug', 'name' => 'name', 'available' => 'available', 'features' => 'features'], null, ['per_page' => 200]))->list();
    }

    /** @return list<Item> */
    public function sizes(?string $region = null): array
    {
        $sizes = (new Endpoint($this->transport, 'size', '/v2/sizes', new DigitalOceanPaginator('sizes'), [
            'slug' => 'slug', 'vcpus' => 'vcpus', 'memoryMb' => 'memory', 'diskGb' => 'disk', 'priceMonthly' => 'price_monthly', 'available' => 'available', 'regions' => 'regions',
        ], null, ['per_page' => 200]))->list();

        return $region === null ? $sizes : array_values(array_filter($sizes, static fn (Item $s): bool => in_array($region, (array) $s->get('regions'), true)));
    }
}
