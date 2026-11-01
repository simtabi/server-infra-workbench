<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\DigitalOcean;

use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Http\Endpoint;
use Simtabi\ServerInfraWorkbench\Http\Transport;
use Simtabi\ServerInfraWorkbench\Safety\PendingAction;
use Simtabi\ServerInfraWorkbench\Support\Item;

/**
 * Tags. Firewalls and alert policies can target a tag, so tagging a droplet can change which rules
 * apply to it: the plan says so.
 */
final readonly class Tags
{
    public const array TYPES = ['droplet', 'image', 'volume', 'volume_snapshot', 'database'];

    private Endpoint $api;

    public function __construct(Transport $transport)
    {
        $this->api = new Endpoint($transport, 'tag', '/v2/tags', new DigitalOceanPaginator('tags'), [
            'name' => 'name', 'resources' => 'resources.count', 'droplets' => 'resources.droplets.count',
        ], 'tag', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /** @return PendingAction<Item> */
    public function create(string $name): PendingAction
    {
        $name = self::name($name);
        foreach ($this->list() as $tag) {
            if ($tag->string('name') === $name) {
                return $this->api->noop('create tag', "{$name} (exists)", $tag);
            }
        }

        return $this->api->create(['name' => $name], $name);
    }

    /**
     * @param list<string> $ids
     * @return PendingAction<array<mixed>>
     */
    public function attach(string $name, string $type, array $ids): PendingAction
    {
        return $this->resources('tag', 'POST', $name, $type, $ids);
    }

    /**
     * @param list<string> $ids
     * @return PendingAction<array<mixed>>
     */
    public function detach(string $name, string $type, array $ids): PendingAction
    {
        return $this->resources('untag', 'DELETE', $name, $type, $ids);
    }

    /**
     * Destructive: firewalls and alert policies that target the tag stop matching anything.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $name): PendingAction
    {
        return $this->api->delete(self::name($name), note: 'firewalls and alert policies targeting this tag stop applying to its resources');
    }

    /**
     * @param list<string> $ids
     * @return PendingAction<array<mixed>>
     */
    private function resources(string $verb, string $method, string $name, string $type, array $ids): PendingAction
    {
        if (! in_array($type, self::TYPES, true)) {
            throw new ValidationException('resource type must be one of '.implode(', ', self::TYPES));
        }
        if ($ids === []) {
            throw new ValidationException('name at least one resource id');
        }
        foreach ($ids as $id) {
            if (preg_match('/^[A-Za-z0-9-]{1,64}$/', $id) !== 1) {
                throw new ValidationException(sprintf('resource id "%s" is not valid', substr($id, 0, 80)));
            }
        }
        $name = self::name($name);
        $body = ['resources' => array_map(static fn (string $id): array => ['resource_id' => $id, 'resource_type' => $type], $ids)];

        return $this->api->call("{$verb} resources", "{$type} ".implode(', ', $ids)." with {$name}", $method, $this->api->path($name, 'resources'), $body,
            note: 'firewalls and alert policies that target this tag follow the change');
    }

    private static function name(string $name): string
    {
        if (preg_match('/^[A-Za-z0-9_:-]{1,255}$/', $name) !== 1) {
            throw new ValidationException(sprintf('tag "%s" may only contain letters, digits, _ : and -', substr($name, 0, 80)));
        }

        return $name;
    }
}
