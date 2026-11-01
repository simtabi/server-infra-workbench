<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Http;

/** A paginator that needs the whole response (e.g. GitHub's Link header), not just the JSON body. */
interface ResponsePaginator extends Paginator
{
    /**
     * @param array<string, int|string|bool> $query
     * @return array<string, int|string|bool>|null
     */
    public function nextFromResponse(ApiResponse $response, array $query): ?array;
}
