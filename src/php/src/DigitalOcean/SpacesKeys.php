<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Security\IssuedCredential;
use Simtabi\VpsServerWorkbench\Security\Secret;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * Spaces (S3-compatible) access keys, scoped per bucket. The secret is returned once, at creation:
 * it comes back as a Secret inside an IssuedCredential, never as a printable field.
 */
final readonly class SpacesKeys
{
    public const array PERMISSIONS = ['read', 'readwrite', 'fullaccess'];

    private Endpoint $api;

    public function __construct(Transport $transport)
    {
        $this->api = new Endpoint($transport, 'spaces key', '/v2/spaces/keys', new DigitalOceanPaginator('keys'), [
            'name' => 'name', 'accessKey' => 'access_key',
            'grants' => static fn (array $r): array => array_map(static fn (array $g): string => (Data::string($g, 'bucket') === '' ? '*' : Data::string($g, 'bucket')).':'.Data::string($g, 'permission'), Data::objects($r, 'grants')),
            'createdAt' => 'created_at',
        ], 'key', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(): array
    {
        return $this->api->list();
    }

    /**
     * A key limited to the given buckets (least privilege). fullaccess (all buckets) needs $buckets = [].
     *
     * @param list<string> $buckets
     * @return PendingAction<IssuedCredential>
     */
    public function create(string $name, array $buckets, string $permission = 'readwrite'): PendingAction
    {
        $name = Validate::label($name, 'key name', 64);
        if (! in_array($permission, self::PERMISSIONS, true)) {
            throw new ValidationException('permission must be one of '.implode(', ', self::PERMISSIONS));
        }
        if ($permission === 'fullaccess' && $buckets !== []) {
            throw new ValidationException('fullaccess covers every bucket; leave out --bucket, or use read/readwrite for specific buckets');
        }
        if ($permission !== 'fullaccess' && $buckets === []) {
            throw new ValidationException('name the bucket(s) the key may use (--bucket b1,b2); fullaccess for all buckets must be asked for explicitly');
        }
        foreach ($this->list() as $key) {
            if ($key->string('name') === $name) {
                throw new ValidationException(sprintf('a Spaces key named "%s" already exists (%s); its secret cannot be shown again. Delete it or pick another name', $name, $key->string('accessKey')));
            }
        }
        $grants = $permission === 'fullaccess'
            ? [['bucket' => '', 'permission' => 'fullaccess']]
            : array_map(static fn (string $b): array => ['bucket' => self::bucket($b), 'permission' => $permission], $buckets);
        $body = ['name' => $name, 'grants' => $grants];
        $transport = $this->api->transport();

        return $transport->pending('create spaces key', "\"{$name}\" ".($permission === 'fullaccess' ? 'fullaccess (all buckets)' : $permission.' on '.implode(', ', $buckets)), 'POST', '/v2/spaces/keys', $body,
            function () use ($transport, $body): IssuedCredential {
                $row = Data::map($transport->send('POST', '/v2/spaces/keys', [], $body)->json, 'key');

                return new IssuedCredential($this->api->item($row), new Secret(Data::string($row, 'secret_key')));
            }, $permission === 'fullaccess', 'the secret is shown only once; it is written to the --out file (chmod 600), never printed');
    }

    /**
     * Destructive: anything using the key loses access immediately.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $accessKey): PendingAction
    {
        return $this->api->delete(Validate::segment($accessKey, 'access key', 128), note: 'apps and backup jobs using this key stop working at once');
    }

    public static function bucket(string $bucket): string
    {
        if (preg_match('/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/', $bucket) !== 1) {
            throw new ValidationException(sprintf('bucket "%s" must be 3-63 lower-case letters, digits and -', $bucket));
        }

        return $bucket;
    }
}
