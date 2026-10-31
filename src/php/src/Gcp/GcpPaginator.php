<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Gcp;

use Simtabi\VpsServerWorkbench\Http\Paginator;
use Simtabi\VpsServerWorkbench\Support\Data;

/**
 * Compute Engine: {items: [...], nextPageToken}. For aggregated lists items is a map of
 * "zones/x" => {<key>: [...]}; pass the key to flatten it.
 */
final readonly class GcpPaginator implements Paginator
{
    public function __construct(private ?string $aggregatedKey = null) {}

    public function items(array $json): array
    {
        if ($this->aggregatedKey === null) {
            return Data::objects($json, 'items');
        }
        $out = [];
        foreach (Data::map($json, 'items') as $scope) {
            if (is_array($scope)) {
                array_push($out, ...Data::objects($scope, $this->aggregatedKey));
            }
        }

        return $out;
    }

    public function next(array $json, array $query): ?array
    {
        $token = Data::nullableString($json, 'nextPageToken');

        return $token === null || $token === '' ? null : ['pageToken' => $token] + $query;
    }
}
