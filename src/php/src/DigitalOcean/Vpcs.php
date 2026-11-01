<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\DigitalOcean;

use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Http\Endpoint;
use Simtabi\VpsServerWorkbench\Http\Transport;
use Simtabi\VpsServerWorkbench\Safety\PendingAction;
use Simtabi\VpsServerWorkbench\Support\Data;
use Simtabi\VpsServerWorkbench\Support\Item;
use Simtabi\VpsServerWorkbench\Support\Validate;

/**
 * VPC networks. Each region has exactly one default VPC, and new droplets land in it unless told
 * otherwise. DigitalOcean refuses to delete the default (or a VPC with members): make another VPC the
 * default first (setDefault), then delete. That is the lesson from the rollout rehearsal.
 */
final readonly class Vpcs
{
    private Endpoint $api;

    public function __construct(Transport $transport)
    {
        $this->api = new Endpoint($transport, 'vpc', '/v2/vpcs', new DigitalOceanPaginator('vpcs'), [
            'id' => 'id', 'name' => 'name', 'region' => 'region', 'ipRange' => 'ip_range', 'default' => 'default', 'createdAt' => 'created_at',
        ], 'vpc', ['per_page' => 200]);
    }

    /** @return list<Item> */
    public function list(?string $region = null): array
    {
        $all = $this->api->list();

        return $region === null ? $all : array_values(array_filter($all, static fn (Item $v): bool => $v->string('region') === $region));
    }

    public function find(string $id): Item
    {
        return $this->api->get(Validate::token($id, 'vpc id'));
    }

    public function defaultFor(string $region): ?Item
    {
        foreach ($this->list(Slug::of($region, 'region')) as $vpc) {
            if ($vpc->get('default') === true) {
                return $vpc;
            }
        }

        return null;
    }

    /** @return list<Item> droplets, databases, load balancers ... in the VPC */
    public function members(string $id): array
    {
        $members = new Endpoint($this->api->transport(), 'vpc member', $this->api->path(Validate::token($id, 'vpc id'), 'members'),
            new DigitalOceanPaginator('members'), ['urn' => 'urn', 'name' => 'name', 'createdAt' => 'created_at'], null, ['per_page' => 200]);

        return $members->list();
    }

    /**
     * Idempotent by name in the region. Without $ipRange DigitalOcean picks a free /20.
     *
     * @return PendingAction<Item>
     */
    public function create(string $name, string $region, ?string $ipRange = null, ?string $description = null): PendingAction
    {
        if (preg_match('/^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$/', $name) !== 1) {
            throw new ValidationException(sprintf('vpc name "%s" may only contain letters, digits, . and - (max 64)', $name));
        }
        $region = Slug::of($region, 'region');
        foreach ($this->list($region) as $vpc) {
            if ($vpc->string('name') === $name) {
                return $this->api->noop('create vpc', "\"{$name}\" (exists: {$vpc->string('id')})", $vpc);
            }
        }
        if ($ipRange !== null) {
            $ipRange = Validate::cidr($ipRange, 'ip range');
            if (! str_contains($ipRange, '/')) {
                throw new ValidationException('the ip range needs a prefix length, e.g. 10.20.0.0/20');
            }
        }
        $body = array_filter(['name' => $name, 'region' => $region, 'ip_range' => $ipRange, 'description' => $description === null ? null : Validate::label($description, 'description')],
            static fn (?string $v): bool => $v !== null);

        return $this->api->create($body, "\"{$name}\" in {$region}".($ipRange !== null ? " ({$ipRange})" : ''), 'free; the range cannot be changed later');
    }

    /**
     * Make this VPC its region's default (new droplets land in it). A no-op when it already is.
     *
     * @return PendingAction<Item>
     */
    public function setDefault(string $id): PendingAction
    {
        $vpc = $this->find($id);
        if ($vpc->get('default') === true) {
            return $this->api->noop('set default vpc', "\"{$vpc->string('name')}\" in {$vpc->string('region')} (already the default)", $vpc);
        }

        return $this->api->update($vpc->string('id'), ['default' => true], "\"{$vpc->string('name')}\" as the default for {$vpc->string('region')}",
            note: 'the previous default stays, but is no longer the default; existing droplets do not move');
    }

    /**
     * Destructive. Refused (here, before DigitalOcean refuses) when it is the default or has members.
     *
     * @return PendingAction<bool>
     */
    public function delete(string $id): PendingAction
    {
        $vpc = $this->find($id);
        if ($vpc->get('default') === true) {
            throw new ValidationException(sprintf('"%s" is the default VPC for %s; DigitalOcean will not delete it. Make another VPC the default first: workbench do vpcs default <other-vpc-id>', $vpc->string('name'), $vpc->string('region')));
        }
        $members = $this->members($vpc->string('id'));
        if ($members !== []) {
            throw new ValidationException(sprintf('"%s" still has %d member(s) (%s); move or delete them first', $vpc->string('name'), count($members), implode(', ', array_map(static fn (Item $m): string => Data::string($m->data, 'name'), $members))));
        }

        return $this->api->delete($vpc->string('id'), "\"{$vpc->string('name')}\" in {$vpc->string('region')}");
    }
}
