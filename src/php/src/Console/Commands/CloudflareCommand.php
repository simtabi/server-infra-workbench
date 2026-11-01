<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console\Commands;

use Simtabi\ServerInfraWorkbench\Cloudflare\Cloudflare;
use Simtabi\ServerInfraWorkbench\Cloudflare\Data\DnsRecord;
use Simtabi\ServerInfraWorkbench\Console\Input;
use Simtabi\ServerInfraWorkbench\Console\ProviderFactory;
use Simtabi\ServerInfraWorkbench\Console\Runner;
use Simtabi\ServerInfraWorkbench\Exception\ValidationException;
use Simtabi\ServerInfraWorkbench\Security\IssuedCredential;
use Simtabi\ServerInfraWorkbench\Support\Item;

/** `siwo cf ...`: Cloudflare API v4. */
final readonly class CloudflareCommand implements Command
{
    public function __construct(private ProviderFactory $providers, private Runner $r) {}

    public function run(Input $in): int
    {
        $r = $this->r;
        $cf = fn (): Cloudflare => $this->providers->cloudflare();

        return match ($in->optionalArg(0)) {
            'verify' => $r->done($in, $cf()->verifyToken() === 'active', 'token is active'),
            'zones' => $r->show($in, $cf()->zones()->list(), ['id' => 'ID', 'name' => 'NAME', 'status' => 'STATUS', 'plan' => 'PLAN']),
            'zone' => $r->showOne($in, $cf()->zones()->find($in->arg(1, 'zone'))),
            'dns' => match ($in->optionalArg(1)) {
                'list' => $r->show($in, $cf()->dns($in->arg(2, 'zone'))->list($in->value('type'), $in->value('name')), ['id' => 'ID', 'type' => 'TYPE', 'name' => 'NAME', 'content' => 'CONTENT', 'ttl' => 'TTL', 'proxied' => 'PROXIED']),
                'upsert' => $r->write($in, $cf()->dns($in->arg(2, 'zone'))->upsert(
                    $in->arg(3, 'type'),
                    $in->arg(4, 'name'),
                    $in->arg(5, 'content'),
                    $in->int('ttl', 1),
                    $in->flag('proxied'),
                    $in->value('priority') === null ? null : $in->int('priority', 10),
                    $in->value('comment'),
                ), fn (DnsRecord $record): int => $r->showOne($in, $record, 'record saved')),
                'delete' => $r->write($in, $cf()->dns($in->arg(2, 'zone'))->delete($in->arg(3, 'record-id')), fn (bool $ok): int => $r->done($in, $ok, 'record deleted')),
                default => $r->usage('cf'),
            },
            'settings' => match ($in->optionalArg(1)) {
                'list', null => $r->showOne($in, $cf()->zones()->settings($in->arg(2, 'zone'))->all()),
                'set' => $r->write($in, $cf()->zones()->settings($in->arg(2, 'zone'))->set($in->arg(3, 'setting'), $in->arg(4, 'value')),
                    fn (string $value): int => $r->done($in, true, "{$in->arg(3, 'setting')} is now {$value}")),
                default => $r->usage('cf'),
            },
            'ssl' => $in->optionalArg(2) === null
                ? $r->done($in, true, 'ssl mode: '.$cf()->zones()->settings($in->arg(1, 'zone'))->get('ssl'))
                : $r->write($in, $cf()->zones()->settings($in->arg(1, 'zone'))->set('ssl', $in->arg(2, 'off|flexible|full|strict')), fn (string $value): int => $r->done($in, true, "ssl mode is now {$value}")),
            'origin-certs' => match ($in->optionalArg(1)) {
                'list', null => $r->show($in, $cf()->zones()->originCertificates($in->arg(2, 'zone'))->list(), ['id' => 'ID', 'hostnames' => 'HOSTNAMES', 'expiresOn' => 'EXPIRES', 'requestType' => 'TYPE']),
                'create' => (function () use ($in, $r, $cf): int {
                    $path = $in->flag('dry-run') ? '' : $r->outPath($in, 'origin certificate private key');
                    if ($path !== '' && file_exists($path.'.crt')) {
                        throw new ValidationException(sprintf('%s.crt already exists; pick a new --out (nothing is overwritten)', $path));
                    }
                    $action = $cf()->zones()->originCertificates($in->arg(2, 'zone'))->create($in->list('hostnames'), $in->int('validity', 5475));

                    return $r->write($in, $action, function (IssuedCredential $c) use ($in, $r, $path): int {
                        $certificate = $c->item->string('certificate');
                        file_put_contents($path.'.crt', $certificate, LOCK_EX); // public half: safe to keep 0644

                        return $r->issued($in, new IssuedCredential(new Item(array_diff_key($c->item->data, ['certificate' => true]) + ['certificateFile' => $path.'.crt']), $c->secret), $path, 'origin certificate issued');
                    });
                })(),
                'revoke' => $r->write($in, $cf()->zones()->originCertificates($in->arg(2, 'zone'))->revoke($in->arg(3, 'certificate-id')), fn (bool $ok): int => $r->done($in, $ok, 'certificate revoked')),
                default => $r->usage('cf'),
            },
            'purge' => $in->flag('everything')
                ? $r->write($in, $cf()->zones()->cache($in->arg(1, 'zone'))->purgeEverything(), fn (bool $ok): int => $r->done($in, $ok, 'cache purged'))
                : $r->write($in, $cf()->zones()->cache($in->arg(1, 'zone'))->purgeFiles($in->list('files') === [] ? throw new ValidationException('give --files <url,url> or --everything') : $in->list('files')),
                    fn (bool $ok): int => $r->done($in, $ok, 'URLs purged')),
            'firewall' => match ($in->optionalArg(1)) {
                'rules', 'list', null => $r->show($in, $cf()->zones()->firewall($in->arg(2, 'zone'))->accessRules(), ['id' => 'ID', 'mode' => 'MODE', 'target' => 'TARGET', 'value' => 'VALUE', 'notes' => 'NOTES']),
                'add' => $r->write($in, $cf()->zones()->firewall($in->arg(2, 'zone'))->addAccessRule($in->arg(3, 'block|challenge|managed_challenge|allow'), $in->value('target') ?? 'ip', $in->arg(4, 'value'), $in->value('comment') ?? ''),
                    fn (Item $i): int => $r->showOne($in, $i, 'access rule added')),
                'delete' => $r->write($in, $cf()->zones()->firewall($in->arg(2, 'zone'))->deleteAccessRule($in->arg(3, 'rule-id')), fn (bool $ok): int => $r->done($in, $ok, 'access rule deleted')),
                'waf' => $r->show($in, $cf()->zones()->firewall($in->arg(2, 'zone'))->customRules(), ['id' => 'ID', 'action' => 'ACTION', 'enabled' => 'ENABLED', 'description' => 'DESCRIPTION', 'expression' => 'EXPRESSION']),
                default => $r->usage('cf'),
            },
            null, 'help' => $r->usage('cf'),
            default => throw new ValidationException(sprintf('unknown "cf %s" (see: siwo cf --help)', $in->arg(0, 'command'))),
        };
    }
}
