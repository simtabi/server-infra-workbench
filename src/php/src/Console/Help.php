<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

final class Help
{
    private const string COMMON = <<<'TXT'


        Flags: --json  machine-readable output     --dry-run, -n  show the plan, send nothing
               --yes, -y  skip the prompt on writes --force  also required for destructive writes
               --verbose  log requests (redacted) to stderr
        Credentials: env vars or ~/.config/vps-server-workbench/credentials (chmod 600). See: workbench credentials
        TXT;

    public static function for(string $area): string
    {
        return match ($area) {
            'do', 'digitalocean' => <<<'TXT'
                workbench do droplets [--tag T]                 list droplets
                workbench do droplet <id>                       one droplet
                workbench do snapshots [<droplet-id>]           list snapshots (all, or one droplet's)
                workbench do snapshot <droplet-id> [--name N] [--wait] [--timeout S]   take a snapshot (write)
                workbench do snapshot-delete <snapshot-id> --force   delete a snapshot (destructive)
                workbench do account                            check the token
                TXT.self::COMMON,
            'cf', 'cloudflare' => <<<'TXT'
                workbench cf zones                              list zones
                workbench cf dns list <zone> [--type A] [--name N]
                workbench cf dns upsert <zone> <type> <name> <content> [--ttl 1] [--proxied] [--priority P] [--comment C]   (write)
                workbench cf dns delete <zone> <record-id> --force   (destructive)
                workbench cf verify                             check the token
                TXT.self::COMMON,
            'ploi' => <<<'TXT'
                workbench ploi servers                          list servers
                workbench ploi server <server-id>               one server
                workbench ploi sites <server-id>                sites on a server
                workbench ploi deploy <server-id> <site-id>     run the site's deploy script (write)
                TXT.self::COMMON,
            'gcp', 'gcloud' => <<<'TXT'
                workbench gcp instances [--zone Z] [--project P]
                workbench gcp snapshots [--project P]
                workbench gcp firewalls [--project P]           WORLD-OPEN marks rules open to 0.0.0.0/0
                workbench gcp snapshot <zone> <disk> [--name N] [--wait]   snapshot a disk (write)
                TXT.self::COMMON,
            default => <<<'TXT'
                workbench — VPS and platform tooling (vps-server-workbench)

                Platform APIs (PHP core):
                  workbench do ...           DigitalOcean: droplets, snapshots
                  workbench cf ...           Cloudflare: zones, DNS records
                  workbench ploi ...         Ploi: servers, sites, deploys
                  workbench gcp ...          Google Compute Engine: instances, snapshots, firewalls
                  workbench credentials      which credentials are configured (never shows values)
                  workbench help <area>      commands for one area
                TXT.self::COMMON,
        };
    }
}
