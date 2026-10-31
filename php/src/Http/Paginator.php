<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Http;

/** One per provider: where the items are in a page, and how to ask for the next page. */
interface Paginator
{
    /**
     * @param array<mixed> $json
     * @return list<array<string, mixed>>
     */
    public function items(array $json): array;

    /**
     * @param array<mixed>                   $json
     * @param array<string, int|string|bool> $query
     * @return array<string, int|string|bool>|null The query for the next page, or null on the last page.
     */
    public function next(array $json, array $query): ?array;
}
