<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Github;

use Simtabi\ServerInfraWorkbench\Http\ApiResponse;
use Simtabi\ServerInfraWorkbench\Http\ResponsePaginator;
use Simtabi\ServerInfraWorkbench\Support\Data;

/**
 * GitHub REST: the page is a JSON array (or an object with a named list, e.g. "workflow_runs") and the
 * next page is the Link header's rel="next" URL. Only its query is reused, so a hostile Link header can
 * never point the client at another host.
 */
final readonly class GithubPaginator implements ResponsePaginator
{
    public function __construct(private ?string $key = null) {}

    public function items(array $json): array
    {
        if ($this->key !== null) {
            return Data::objects($json, $this->key);
        }

        return Data::objects(['page' => $json], 'page');
    }

    /** Body-only fallback: GitHub never puts paging in the body. */
    public function next(array $json, array $query): ?array
    {
        return null;
    }

    public function nextFromResponse(ApiResponse $response, array $query): ?array
    {
        $next = self::nextUrl($response->header('link') ?? '');
        if ($next === null) {
            return null;
        }
        parse_str((string) parse_url($next, PHP_URL_QUERY), $params);
        $out = $query;
        foreach ($params as $name => $value) {
            if (is_string($name) && is_string($value) && preg_match('/^[a-z_]{1,32}$/', $name) === 1) {
                $out[$name] = ctype_digit($value) ? (int) $value : $value;
            }
        }

        return $out === $query ? null : $out;
    }

    public static function nextUrl(string $link): ?string
    {
        foreach (explode(',', $link) as $part) {
            if (preg_match('/<([^>]+)>\s*;\s*rel="?next"?/', trim($part), $m) === 1) {
                return $m[1];
            }
        }

        return null;
    }
}
