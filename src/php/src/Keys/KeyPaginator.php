<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Keys;

use Simtabi\VpsServerWorkbench\Http\Paginator;
use Simtabi\VpsServerWorkbench\Support\Data;

/** The paging styles of the SSH-key APIs. */
final readonly class KeyPaginator implements Paginator
{
    public function __construct(private string $style, private string $listField, private int $pageSize) {}

    public function items(array $json): array
    {
        if ($this->listField === '') {
            $out = [];
            foreach ($json as $row) {
                if (is_array($row)) {
                    $item = [];
                    foreach ($row as $k => $v) {
                        $item[(string) $k] = $v;
                    }
                    $out[] = $item;
                }
            }

            return $out;
        }

        return Data::objects($json, $this->listField);
    }

    public function next(array $json, array $query): ?array
    {
        switch ($this->style) {
            case 'digitalocean':
                $next = Data::nullableString($json, 'links.pages.next');
                if ($next === null) {
                    return null;
                }
                parse_str((string) parse_url($next, PHP_URL_QUERY), $params);
                $page = $params['page'] ?? null;

                return is_string($page) && ctype_digit($page) ? ['page' => (int) $page] + $query : null;
            case 'cursor':
                $cursor = Data::string($json, 'meta.links.next');

                return $cursor === '' ? null : ['cursor' => $cursor] + $query;
            case 'hetzner':
                $page = Data::int($json, 'meta.pagination.next_page');

                return $page > 0 ? ['page' => $page] + $query : null;
            case 'linode':
                $page = Data::int($json, 'page', 1);

                return $page < Data::int($json, 'pages', 1) ? ['page' => $page + 1] + $query : null;
            case 'scaleway':
                $page = is_int($query['page'] ?? null) ? $query['page'] : 1;

                return count($this->items($json)) < $this->pageSize ? null : ['page' => $page + 1] + $query;
            default:
                return null;
        }
    }
}
