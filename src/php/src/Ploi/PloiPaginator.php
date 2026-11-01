<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Ploi;

use Simtabi\ServerInfraWorkbench\Http\Paginator;
use Simtabi\ServerInfraWorkbench\Support\Data;

/** Ploi (Laravel style): {data: [...], meta: {current_page, last_page}}. */
final class PloiPaginator implements Paginator
{
    public function items(array $json): array
    {
        return Data::objects($json, 'data');
    }

    public function next(array $json, array $query): ?array
    {
        $page = Data::int($json, 'meta.current_page', 1);

        return $page < Data::int($json, 'meta.last_page', 1) ? ['page' => $page + 1] + $query : null;
    }
}
