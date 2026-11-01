<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean;

use Simtabi\ServerInfraWorkbench\Http\Paginator;
use Simtabi\ServerInfraWorkbench\Support\Data;

/** DigitalOcean: items under a named key, next page in links.pages.next. */
final readonly class DigitalOceanPaginator implements Paginator
{
    public function __construct(private string $key) {}

    public function items(array $json): array
    {
        return Data::objects($json, $this->key);
    }

    public function next(array $json, array $query): ?array
    {
        $next = Data::nullableString($json, 'links.pages.next');
        if ($next === null) {
            return null;
        }
        parse_str((string) parse_url($next, PHP_URL_QUERY), $params);
        $page = $params['page'] ?? null;

        return is_string($page) && ctype_digit($page) ? ['page' => (int) $page] + $query : null;
    }
}
