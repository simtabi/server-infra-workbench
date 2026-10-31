<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Cloudflare;

use Simtabi\VpsServerWorkbench\Exception\ApiException;
use Simtabi\VpsServerWorkbench\Http\Paginator;
use Simtabi\VpsServerWorkbench\Support\Data;

/** Cloudflare v4: {success, errors, result, result_info: {page, total_pages}}. */
final class CloudflarePaginator implements Paginator
{
    public function items(array $json): array
    {
        self::assertSuccess($json);

        return Data::objects($json, 'result');
    }

    public function next(array $json, array $query): ?array
    {
        $page = Data::int($json, 'result_info.page', 1);

        return $page < Data::int($json, 'result_info.total_pages', 1) ? ['page' => $page + 1] + $query : null;
    }

    /**
     * Cloudflare can answer 200 with success=false.
     *
     * @param array<mixed> $json
     * @return array<string, mixed>
     */
    public static function result(array $json): array
    {
        self::assertSuccess($json);

        return Data::map($json, 'result');
    }

    /** @param array<mixed> $json */
    private static function assertSuccess(array $json): void
    {
        if (Data::get($json, 'success') === false) {
            throw new ApiException('Cloudflare request failed: '.ApiException::detail($json), 'Cloudflare', 200);
        }
    }
}
