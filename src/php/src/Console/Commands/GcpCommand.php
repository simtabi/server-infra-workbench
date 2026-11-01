<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console\Commands;

use Simtabi\VpsServerWorkbench\Console\Input;
use Simtabi\VpsServerWorkbench\Console\ProviderFactory;
use Simtabi\VpsServerWorkbench\Console\Runner;
use Simtabi\VpsServerWorkbench\Exception\ValidationException;
use Simtabi\VpsServerWorkbench\Gcp\Gcp;
use Simtabi\VpsServerWorkbench\Gcp\RunningOperation;
use Simtabi\VpsServerWorkbench\Support\Item;

/** `workbench gcp ...`: Compute Engine, Cloud DNS and Cloud Storage. */
final readonly class GcpCommand implements Command
{
    public function __construct(private ProviderFactory $providers, private Runner $r) {}

    public function run(Input $in): int
    {
        $r = $this->r;
        $gcp = fn (): Gcp => $this->providers->gcp($in->value('project'));

        return match ($in->optionalArg(0)) {
            'instances' => $r->show($in, $gcp()->instances()->list($in->value('zone')), ['name' => 'NAME', 'zone' => 'ZONE', 'status' => 'STATUS', 'machineType' => 'TYPE', 'internalIp' => 'INTERNAL IP', 'externalIp' => 'EXTERNAL IP']),
            'instance' => $this->instance($in, $gcp()),
            'snapshots' => $r->show($in, $gcp()->snapshots()->list(), ['name' => 'NAME', 'status' => 'STATUS', 'sourceDisk' => 'DISK', 'diskSizeGb' => 'GB', 'createdAt' => 'CREATED']),
            'snapshot' => $r->write($in, $gcp()->snapshots()->create($in->arg(1, 'zone'), $in->arg(2, 'disk'), $in->value('name')), fn (RunningOperation $op): int => $this->operation($in, $op, 'snapshot')),
            'snapshot-delete' => $r->write($in, $gcp()->snapshots()->delete($in->arg(1, 'snapshot')), fn (RunningOperation $op): int => $this->operation($in, $op, 'snapshot delete')),
            'firewalls' => $r->show($in, $gcp()->firewalls()->list(), ['name' => 'NAME', 'network' => 'NETWORK', 'direction' => 'DIR', 'allowed' => 'ALLOW', 'sourceRanges' => 'SOURCES', 'openToWorld' => 'WORLD-OPEN']),
            'firewall-create' => $r->write($in, $gcp()->firewalls()->create($in->arg(1, 'name'), $in->list('allow'), $in->list('source-ranges'), $in->list('target-tags'), $in->value('network') ?? 'default', $in->int('priority', 1000), $in->value('description') ?? ''),
                fn (RunningOperation $op): int => $this->operation($in, $op, 'firewall rule')),
            'firewall-delete' => $r->write($in, $gcp()->firewalls()->delete($in->arg(1, 'name')), fn (RunningOperation $op): int => $this->operation($in, $op, 'firewall delete')),
            'dns' => $this->dns($in, $gcp()),
            'buckets' => $this->buckets($in, $gcp()),
            null, 'help' => $r->usage('gcp'),
            default => throw new ValidationException(sprintf('unknown "gcp %s" (see: workbench gcp --help)', $in->arg(0, 'command'))),
        };
    }

    private function instance(Input $in, Gcp $gcp): int
    {
        $r = $this->r;
        $i = $gcp->instances();
        $zone = fn (): string => $in->required('zone', 'e.g. us-east1-b');
        $done = fn (string $what): \Closure => fn (RunningOperation $op): int => $this->operation($in, $op, $what);

        return match ($in->optionalArg(1)) {
            'show' => $r->showOne($in, $i->find($zone(), $in->arg(2, 'instance'))),
            'create' => $r->write($in, $i->create($zone(), $in->arg(2, 'instance'), $in->value('size') ?? 'e2-small', $in->value('image') ?? 'projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64',
                $in->int('disk-gb', 20), $in->list('tag'), $in->value('network') ?? 'default'), $done('create')),
            'start' => $r->write($in, $i->start($zone(), $in->arg(2, 'instance')), $done('start')),
            'stop' => $r->write($in, $i->stop($zone(), $in->arg(2, 'instance')), $done('stop')),
            'reset' => $r->write($in, $i->reset($zone(), $in->arg(2, 'instance')), $done('reset')),
            'delete' => $r->write($in, $i->delete($zone(), $in->arg(2, 'instance')), $done('delete')),
            default => $r->usage('gcp'),
        };
    }

    private function dns(Input $in, Gcp $gcp): int
    {
        $r = $this->r;
        $dns = $gcp->dns();
        $change = fn (string $what): \Closure => fn (array $unused): int => $r->done($in, true, $what);

        return match ($in->optionalArg(1)) {
            'zones', null => $r->show($in, $dns->zones(), ['name' => 'NAME', 'dnsName' => 'DNS NAME', 'visibility' => 'VISIBILITY', 'dnssec' => 'DNSSEC', 'nameServers' => 'NAME SERVERS']),
            'zone-create' => $r->write($in, $dns->createZone($in->arg(2, 'domain'), $in->value('name')), fn (Item $z): int => $r->showOne($in, $z, 'zone created; point the registrar at its name servers')),
            'zone-delete' => $r->write($in, $dns->deleteZone($in->arg(2, 'zone')), fn (bool $ok): int => $r->done($in, $ok, 'zone deleted')),
            'list' => $r->show($in, $dns->records($in->arg(2, 'zone'), $in->value('type'), $in->value('name')), ['name' => 'NAME', 'type' => 'TYPE', 'ttl' => 'TTL', 'data' => 'DATA']),
            'upsert' => $r->write($in, $dns->upsert($in->arg(2, 'zone'), $in->arg(3, 'type'), $in->arg(4, 'name'), $in->rest(5, 'value'), $in->int('ttl', 300)), $change('record set saved')),
            'delete' => $r->write($in, $dns->delete($in->arg(2, 'zone'), $in->arg(3, 'type'), $in->arg(4, 'name')), $change('record set deleted')),
            default => $r->usage('gcp'),
        };
    }

    private function buckets(Input $in, Gcp $gcp): int
    {
        $r = $this->r;
        $s = $gcp->storage();

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $s->list(), ['name' => 'NAME', 'location' => 'LOCATION', 'storageClass' => 'CLASS', 'publicAccessPrevention' => 'PUBLIC ACCESS', 'versioning' => 'VERSIONING']),
            'show' => $r->showOne($in, $s->find($in->arg(2, 'bucket'))),
            'create' => $r->write($in, $s->create($in->arg(2, 'bucket'), $in->value('location') ?? 'US', $in->value('storage-class') ?? 'STANDARD',
                $in->value('retention-days') === null ? null : $in->int('retention-days', 0)), fn (Item $b): int => $r->showOne($in, $b, 'bucket created (private)')),
            'delete' => $r->write($in, $s->delete($in->arg(2, 'bucket')), fn (bool $ok): int => $r->done($in, $ok, 'bucket deleted')),
            'objects' => $r->show($in, $s->objects($in->arg(2, 'bucket'), $in->value('prefix') ?? '', $in->int('limit', 100)), ['name' => 'NAME', 'size' => 'BYTES', 'storageClass' => 'CLASS', 'updated' => 'UPDATED']),
            default => $r->usage('gcp'),
        };
    }

    private function operation(Input $in, RunningOperation $running, string $what): int
    {
        $op = $in->flag('wait') ? $running->wait($in->int('timeout', 1800)) : $running->operation();

        return $this->r->showOne($in, $op, $in->flag('wait') ? "{$what} finished" : "{$what} started (add --wait to wait for it)");
    }
}
