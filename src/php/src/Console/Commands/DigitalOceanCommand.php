<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console\Commands;

use Simtabi\ServerInfraWorkbench\Console\Input;
use Simtabi\ServerInfraWorkbench\Console\ProviderFactory;
use Simtabi\ServerInfraWorkbench\Console\Runner;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\Droplet;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\Firewall;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\UptimeAlert;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Data\UptimeCheck;
use Simtabi\ServerInfraWorkbench\DigitalOcean\DigitalOcean;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Droplets;
use Simtabi\ServerInfraWorkbench\DigitalOcean\FirewallPreset;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Monitoring;
use Simtabi\ServerInfraWorkbench\DigitalOcean\RunningAction;
use Simtabi\ServerInfraWorkbench\DigitalOcean\Uptime;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Security\IssuedCredential;
use Simtabi\ServerInfraWorkbench\Support\Item;

/** `siwo do ...`: DigitalOcean API v2. */
final readonly class DigitalOceanCommand implements Command
{
    public function __construct(private ProviderFactory $providers, private Runner $r) {}

    public function run(Input $in): int
    {
        $r = $this->r;
        $do = fn (): DigitalOcean => $this->providers->digitalOcean();

        return match ($in->optionalArg(0)) {
            'account' => $r->showOne($in, $do()->account()),
            'regions' => $r->show($in, $do()->catalog()->regions(), ['slug' => 'SLUG', 'name' => 'NAME', 'available' => 'AVAILABLE']),
            'sizes' => $r->show($in, $do()->catalog()->sizes($in->value('region')), ['slug' => 'SLUG', 'vcpus' => 'VCPU', 'memoryMb' => 'MEM MB', 'diskGb' => 'DISK GB', 'priceMonthly' => '$/MO']),
            'droplets' => $r->show($in, $do()->droplets()->list($in->value('tag')), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'region' => 'REGION', 'size' => 'SIZE', 'publicIpv4' => 'PUBLIC IP', 'privateIpv4' => 'PRIVATE IP']),
            'droplet' => $r->showOne($in, $do()->droplets()->find($in->arg(1, 'droplet-id'))),
            'droplet-create' => $r->write($in, $do()->droplets()->create(
                $in->arg(1, 'name'),
                $in->required('region', 'e.g. nyc3'),
                $in->required('size', 'e.g. s-2vcpu-4gb; see: siwo do sizes'),
                $do()->droplets()->resolveImage($in->value('image') ?? $this->providers->credentials()->setting(Droplets::IMAGE_ENV)),
                $in->list('ssh-keys'),
                $in->value('vpc'),
                $in->list('tag'),
                $in->flag('backups'),
                $r->readFile($in->value('user-data')),
            ), fn (Droplet $d): int => $r->showOne($in, $d, 'droplet created (it boots in about a minute; see: siwo do droplet '.$d->id.')')),
            'droplet-delete' => $r->write($in, $do()->droplets()->delete($in->arg(1, 'droplet-id')), fn (bool $ok): int => $r->done($in, $ok, 'droplet deleted')),
            'power' => $r->write($in, $do()->droplets()->power($in->arg(1, 'droplet-id'), $in->arg(2, implode('|', Droplets::POWER))), fn (RunningAction $a): int => $this->action($in, $a, 'power action')),
            'resize' => $r->write($in, $do()->droplets()->resize($in->arg(1, 'droplet-id'), $in->required('size', 'e.g. s-2vcpu-4gb; see: siwo do sizes'), $in->flag('disk'), $in->int('timeout', 1800)),
                fn (Droplet $d): int => $r->showOne($in, $d, 'droplet resized and powered on')),
            'snapshots' => $r->show($in, $in->optionalArg(1) === null ? $do()->snapshots()->list() : $do()->droplets()->snapshots($in->arg(1, 'droplet-id')), ['id' => 'ID', 'name' => 'NAME', 'resourceId' => 'DROPLET', 'sizeGb' => 'GB', 'createdAt' => 'CREATED']),
            'snapshot' => $r->write($in, $do()->droplets()->snapshot($in->arg(1, 'droplet-id'), $in->value('name')), fn (RunningAction $a): int => $this->action($in, $a, 'snapshot')),
            'snapshot-delete' => $r->write($in, $do()->snapshots()->delete($in->arg(1, 'snapshot-id')), fn (bool $ok): int => $r->done($in, $ok, 'snapshot deleted')),
            'volumes' => $this->volumes($in, $do()),
            'vpcs' => $this->vpcs($in, $do()),
            'spaces-keys' => $this->spacesKeys($in, $do()),
            'domains' => $this->domains($in, $do()),
            'dns' => $this->dns($in, $do()),
            'reserved-ips' => $this->reservedIps($in, $do()),
            'projects' => $this->projects($in, $do()),
            'tags' => $this->tags($in, $do()),
            'alerts' => $this->alerts($in, $do()),
            'firewalls' => $r->show($in, $do()->firewalls()->list(), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'dropletIds' => 'DROPLETS', 'tags' => 'TAGS', 'openToWorld' => 'WORLD-OPEN']),
            'firewall-apply' => $r->write($in, $do()->firewalls()->apply(FirewallPreset::build(
                $in->arg(1, 'db|web'),
                $in->value('name') ?? 'workbench-'.$in->arg(1, 'db|web'),
                $this->vpcCidr($in, $do()),
                $in->list('ssh-from'),
                $in->value('ports') === null ? FirewallPreset::DB_PORTS : $in->ints('ports'),
                $in->ints('droplet'),
                $in->list('tag'),
            )), fn (Firewall $f): int => $r->showOne($in, $f, 'firewall applied')),
            'firewall-delete' => $r->write($in, $do()->firewalls()->delete($in->arg(1, 'firewall-id')), fn (bool $ok): int => $r->done($in, $ok, 'firewall deleted')),
            'uptime' => $this->uptime($in, $do()),
            null, 'help' => $r->usage('do'),
            default => throw new ValidationException(sprintf('unknown "do %s" (see: siwo do --help)', $in->arg(0, 'command'))),
        };
    }

    private function action(Input $in, RunningAction $running, string $what): int
    {
        $action = $in->flag('wait') ? $running->wait($in->int('timeout', 1800)) : $running->action();

        return $this->r->showOne($in, $action, $in->flag('wait') ? "{$what} finished" : "{$what} started (add --wait to wait for it)");
    }

    private function volumes(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;
        $v = $do->volumes();

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $v->list($in->value('region')), ['id' => 'ID', 'name' => 'NAME', 'region' => 'REGION', 'sizeGb' => 'GB', 'dropletIds' => 'DROPLETS', 'filesystem' => 'FS']),
            'create' => $r->write($in, $v->create($in->arg(2, 'name'), $in->required('region', 'e.g. nyc3'), $in->int('size-gb', 0), $in->value('filesystem') ?? 'ext4', $in->list('tag')),
                fn (Item $i): int => $r->showOne($in, $i, 'volume created')),
            'attach' => $r->write($in, $v->attach($in->arg(2, 'volume-id'), $in->required('droplet', 'droplet id')), fn (RunningAction $a): int => $this->action($in, $a, 'attach')),
            'detach' => $r->write($in, $v->detach($in->arg(2, 'volume-id'), $in->required('droplet', 'droplet id')), fn (RunningAction $a): int => $this->action($in, $a, 'detach')),
            'resize' => $r->write($in, $v->resize($in->arg(2, 'volume-id'), $in->int('size-gb', 0)), fn (RunningAction $a): int => $this->action($in, $a, 'resize')),
            'delete' => $r->write($in, $v->delete($in->arg(2, 'volume-id')), fn (bool $ok): int => $r->done($in, $ok, 'volume deleted')),
            default => $r->usage('do'),
        };
    }

    private function vpcs(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;
        $v = $do->vpcs();

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $v->list($in->value('region')), ['id' => 'ID', 'name' => 'NAME', 'region' => 'REGION', 'ipRange' => 'RANGE', 'default' => 'DEFAULT']),
            'members' => $r->show($in, $v->members($in->arg(2, 'vpc-id')), ['urn' => 'URN', 'name' => 'NAME', 'createdAt' => 'CREATED']),
            'create' => $r->write($in, $v->create($in->arg(2, 'name'), $in->required('region', 'e.g. nyc3'), $in->value('ip-range'), $in->value('description')),
                fn (Item $i): int => $r->showOne($in, $i, 'vpc created')),
            'default' => $r->write($in, $v->setDefault($in->arg(2, 'vpc-id')), fn (Item $i): int => $r->showOne($in, $i, 'vpc is now the region default')),
            'delete' => $r->write($in, $v->delete($in->arg(2, 'vpc-id')), fn (bool $ok): int => $r->done($in, $ok, 'vpc deleted')),
            default => $r->usage('do'),
        };
    }

    private function spacesKeys(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;
        $k = $do->spacesKeys();

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $k->list(), ['name' => 'NAME', 'accessKey' => 'ACCESS KEY', 'grants' => 'GRANTS', 'createdAt' => 'CREATED']),
            'create' => (function () use ($in, $r, $k): int {
                $path = $in->flag('dry-run') ? '' : $r->outPath($in, 'Spaces secret key');
                $action = $k->create($in->arg(2, 'name'), $in->list('bucket'), $in->value('permission') ?? 'readwrite');

                return $r->write($in, $action, fn (IssuedCredential $c): int => $r->issued($in, $c, $path, 'Spaces key created'));
            })(),
            'delete' => $r->write($in, $k->delete($in->arg(2, 'access-key')), fn (bool $ok): int => $r->done($in, $ok, 'Spaces key deleted')),
            default => $r->usage('do'),
        };
    }

    private function domains(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $do->domains()->list(), ['name' => 'NAME', 'ttl' => 'TTL']),
            'create' => $r->write($in, $do->domains()->create($in->arg(2, 'domain'), $in->value('ip')), fn (Item $i): int => $r->showOne($in, $i, 'domain added')),
            'delete' => $r->write($in, $do->domains()->delete($in->arg(2, 'domain')), fn (bool $ok): int => $r->done($in, $ok, 'domain deleted')),
            default => $r->usage('do'),
        };
    }

    private function dns(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;

        return match ($in->optionalArg(1)) {
            'list' => $r->show($in, $do->domains()->records($in->arg(2, 'domain'))->list($in->value('type'), $in->value('name')), ['id' => 'ID', 'type' => 'TYPE', 'name' => 'NAME', 'data' => 'DATA', 'ttl' => 'TTL']),
            'upsert' => $r->write($in, $do->domains()->records($in->arg(2, 'domain'))->upsert($in->arg(3, 'type'), $in->arg(4, 'name'), $in->arg(5, 'data'), $in->int('ttl', 1800),
                $in->value('priority') === null ? null : $in->int('priority', 10)), fn (Item $i): int => $r->showOne($in, $i, 'record saved')),
            'delete' => $r->write($in, $do->domains()->records($in->arg(2, 'domain'))->delete($in->arg(3, 'record-id')), fn (bool $ok): int => $r->done($in, $ok, 'record deleted')),
            default => $r->usage('do'),
        };
    }

    private function reservedIps(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;
        $ips = $do->reservedIps();

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $ips->list(), ['ip' => 'IP', 'region' => 'REGION', 'dropletId' => 'DROPLET', 'dropletName' => 'NAME']),
            'create' => $r->write($in, $ips->create($in->value('region'), $in->value('droplet')), fn (Item $i): int => $r->showOne($in, $i, 'reserved IP created')),
            'assign' => $r->write($in, $ips->assign($in->arg(2, 'ip'), $in->required('droplet', 'droplet id')), fn (RunningAction $a): int => $this->action($in, $a, 'assign')),
            'unassign' => $r->write($in, $ips->unassign($in->arg(2, 'ip')), fn (RunningAction $a): int => $this->action($in, $a, 'unassign')),
            'delete' => $r->write($in, $ips->delete($in->arg(2, 'ip')), fn (bool $ok): int => $r->done($in, $ok, 'reserved IP released')),
            default => $r->usage('do'),
        };
    }

    private function projects(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $do->projects()->list(), ['id' => 'ID', 'name' => 'NAME', 'purpose' => 'PURPOSE', 'environment' => 'ENV', 'default' => 'DEFAULT']),
            'resources' => $r->show($in, $do->projects()->resources($in->arg(2, 'project-id')), ['urn' => 'URN', 'status' => 'STATUS', 'assignedAt' => 'ASSIGNED']),
            'assign' => $r->write($in, $do->projects()->assign($in->arg(2, 'project-id'), $in->rest(3, 'urn (do:droplet:123)')), fn (array $unused): int => $r->done($in, true, 'resources moved')),
            default => $r->usage('do'),
        };
    }

    private function tags(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;
        $t = $do->tags();

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $t->list(), ['name' => 'NAME', 'resources' => 'RESOURCES', 'droplets' => 'DROPLETS']),
            'create' => $r->write($in, $t->create($in->arg(2, 'tag')), fn (Item $i): int => $r->showOne($in, $i, 'tag created')),
            'attach' => $r->write($in, $t->attach($in->arg(2, 'tag'), $in->value('type') ?? 'droplet', $in->rest(3, 'resource-id')), fn (array $unused): int => $r->done($in, true, 'tagged')),
            'detach' => $r->write($in, $t->detach($in->arg(2, 'tag'), $in->value('type') ?? 'droplet', $in->rest(3, 'resource-id')), fn (array $unused): int => $r->done($in, true, 'untagged')),
            'delete' => $r->write($in, $t->delete($in->arg(2, 'tag')), fn (bool $ok): int => $r->done($in, $ok, 'tag deleted')),
            default => $r->usage('do'),
        };
    }

    private function alerts(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;

        return match ($in->optionalArg(1)) {
            'list', null => $r->show($in, $do->monitoring()->policies(), ['uuid' => 'UUID', 'description' => 'DESCRIPTION', 'enabled' => 'ENABLED', 'emails' => 'EMAILS']),
            'create' => $r->write($in, $do->monitoring()->apply([Monitoring::body(
                $in->required('type', implode('|', array_keys(Monitoring::TYPES))),
                (float) $in->required('value', 'e.g. 85 for 85%'),
                $in->value('window') ?? '5m', $in->list('email'), $in->ints('droplet'), $in->list('tag'),
                $in->flag('below') ? 'LessThan' : 'GreaterThan',
            )]), fn (array $p): int => $r->show($in, $p, ['uuid' => 'UUID', 'description' => 'DESCRIPTION'])),
            'standard' => $r->write($in, $do->monitoring()->apply(Monitoring::standard($in->list('email'), $in->ints('droplet'), $in->list('tag'))),
                fn (array $p): int => $p === [] ? $r->done($in, true, 'all standard alert policies already exist') : $r->show($in, $p, ['uuid' => 'UUID', 'description' => 'DESCRIPTION'])),
            'delete' => $r->write($in, $do->monitoring()->delete($in->arg(2, 'policy-uuid')), fn (bool $ok): int => $r->done($in, $ok, 'alert policy deleted')),
            default => $r->usage('do'),
        };
    }

    private function uptime(Input $in, DigitalOcean $do): int
    {
        $r = $this->r;

        return match ($in->optionalArg(1)) {
            'checks', null => $r->show($in, $do->uptime()->checks(), ['id' => 'ID', 'name' => 'NAME', 'type' => 'TYPE', 'target' => 'TARGET', 'regions' => 'REGIONS', 'enabled' => 'ENABLED']),
            'state' => $r->showOne($in, $do->uptime()->state($in->arg(2, 'check-id'))),
            'check-create' => $r->write($in, $do->uptime()->createCheck($in->arg(2, 'name'), $in->arg(3, 'url-or-host'), $in->value('type') ?? 'https', $in->list('regions') === [] ? Uptime::REGIONS : $in->list('regions')),
                fn (UptimeCheck $c): int => $r->showOne($in, $c, 'uptime check saved')),
            'check-delete' => $r->write($in, $do->uptime()->deleteCheck($in->arg(2, 'check-id')), fn (bool $ok): int => $r->done($in, $ok, 'uptime check deleted')),
            'alerts' => $r->show($in, $do->uptime()->alerts($in->arg(2, 'check-id')), ['id' => 'ID', 'name' => 'NAME', 'type' => 'TYPE', 'threshold' => 'THRESHOLD', 'period' => 'PERIOD', 'emails' => 'EMAILS']),
            'alert-create' => $r->write($in, $do->uptime()->createAlert($in->arg(2, 'check-id'), $in->arg(3, 'type'), $in->list('email'), $in->int('threshold', 0), $in->value('period') ?? '2m', $in->value('name')),
                fn (UptimeAlert $a): int => $r->showOne($in, $a, 'uptime alert created')),
            default => $r->usage('do'),
        };
    }

    private function vpcCidr(Input $in, DigitalOcean $do): string
    {
        $vpc = $in->required('vpc', 'a VPC id (looked up) or its CIDR, e.g. 10.0.0.0/20');

        return str_contains($vpc, '/') ? FirewallPreset::cidr($vpc) : $do->firewalls()->vpcCidr($vpc);
    }
}
