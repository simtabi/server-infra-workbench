<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Cloudflare;

use Simtabi\VpsServerWorkbench\Cloudflare\Data\Zone;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;

/** Cache purge. By URL is cheap; everything sends a full wave of traffic back to the origin. */
final readonly class Cache
{
    public function __construct(private Transport $transport, private Zone $zone) {}

    /**
     * @param list<string> $files full URLs (max 30 per call)
     * @return PendingAction<bool>
     */
    public function purgeFiles(array $files): PendingAction
    {
        if ($files === [] || count($files) > 30) {
            throw new ValidationException('purge 1 to 30 URLs at a time');
        }
        foreach ($files as $url) {
            $host = parse_url($url, PHP_URL_HOST);
            if (! str_starts_with($url, 'https://') && ! str_starts_with($url, 'http://') || ! is_string($host)
                || ($host !== $this->zone->name && ! str_ends_with($host, '.'.$this->zone->name))) {
                throw new ValidationException(sprintf('"%s" is not a URL inside %s', substr($url, 0, 120), $this->zone->name));
            }
        }

        return $this->purge(['files' => $files], count($files).' URL(s) on '.$this->zone->name, false, null);
    }

    /** @return PendingAction<bool> */
    public function purgeEverything(): PendingAction
    {
        return $this->purge(['purge_everything' => true], 'everything on '.$this->zone->name, true, 'every request goes to the origin until the cache warms up again');
    }

    /**
     * @param array<string, mixed> $body
     * @return PendingAction<bool>
     */
    private function purge(array $body, string $target, bool $destructive, ?string $note): PendingAction
    {
        $path = "/zones/{$this->zone->id}/purge_cache";

        return $this->transport->pending('purge cache', $target, 'POST', $path, $body, function () use ($path, $body): bool {
            CloudflarePaginator::result($this->transport->send('POST', $path, [], $body)->json);

            return true;
        }, $destructive, $note);
    }
}
