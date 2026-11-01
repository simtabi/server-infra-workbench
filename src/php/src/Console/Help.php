<?php

declare(strict_types=1);

namespace Simtabi\VpsServerWorkbench\Console;

final class Help
{
    private const string COMMON = <<<'TXT'


        Flags: --json  machine-readable output     --dry-run, -n  show the plan, send nothing
               --yes, -y  skip the prompt on writes --force  also required for destructive writes
               --verbose  log requests (redacted) to stderr
               --quiet, -q  no progress on long waits (VSW_PROGRESS=auto|tty|plain|off, NO_COLOR)
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
                workbench do resize <droplet-id> --size S [--disk] [--timeout S]   shutdown, resize, power on (write;
                        downtime; --disk is permanent and needs --force). Snapshot first.
                workbench do alerts [list]                      monitoring alert policies
                workbench do alerts standard --email a@x (--droplet ID[,ID] | --tag T)   cpu>85% 10m, memory>90% 10m,
                        disk>85% 5m; creates only the missing ones (write)
                workbench do alerts create --type cpu|memory|disk|load1|load5|load15|bandwidth-out --value N
                        [--window 5m|10m|30m|1h] [--below] --email a@x (--droplet ID | --tag T)   (write)
                workbench do alerts delete <uuid> --force       (destructive)
                workbench do droplet-create <name> --region R --size S --ssh-keys ID[,ID] [--image I|latest]
                        [--vpc UUID] [--tag T[,T]] [--backups] [--user-data FILE]   create a droplet (write; idempotent by name;
                        image: --image, else VSW_DROPLET_IMAGE, else ubuntu-26-04-x64, the newest Ubuntu LTS;
                        "latest" asks the API for the newest Ubuntu LTS)
                workbench do firewalls                          cloud firewalls (WORLD-OPEN marks non-web ports open to all)
                workbench do firewall-apply db|web --vpc VPC_ID|CIDR [--name N] [--ssh-from CIDR[,CIDR]]
                        [--ports 5432,6379] [--droplet ID[,ID]] [--tag T]   create or update a preset (write)
                workbench do firewall-delete <firewall-id> --force   (destructive)
                workbench do uptime [checks]                    uptime checks
                workbench do uptime state <check-id>            up/down per region
                workbench do uptime check-create <name> <url> [--type https|http|ping] [--regions us_east,eu_west]   (write)
                workbench do uptime check-delete <check-id> --force   (destructive)
                workbench do uptime alerts <check-id>
                workbench do uptime alert-create <check-id> down|down_global|latency|ssl_expiry --email a@x[,b@y]
                        [--threshold N] [--period 2m|5m|...|1h] [--name N]   (write)
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
                workbench ploi site-create <server-id> <domain> [--web-directory /public] [--project-type laravel] [--user ploi]   (write)
                workbench ploi site-delete <server-id> <site-id> --force   (destructive)
                workbench ploi deploy-script <server-id> <site-id>         print the deploy script
                workbench ploi deploy-script-set <server-id> <site-id> --file deploy.sh   replace it (write; no-op if identical)
                workbench ploi daemons <server-id>
                workbench ploi daemon-create <server-id> --command "php artisan queue:work" [--user ploi] [--processes 1] [--directory D]   (write)
                workbench ploi daemon-delete <server-id> <daemon-id> --force   (destructive)
                TXT.self::COMMON,
            'gcp', 'gcloud' => <<<'TXT'
                workbench gcp instances [--zone Z] [--project P]
                workbench gcp snapshots [--project P]
                workbench gcp firewalls [--project P]           WORLD-OPEN marks rules open to 0.0.0.0/0
                workbench gcp snapshot <zone> <disk> [--name N] [--wait]   snapshot a disk (write)
                TXT.self::COMMON,
            'keys' => <<<'TXT'
                workbench keys                                  interactive menu (account and server keys)
                workbench keys providers                        providers, and which have credentials
                workbench keys fingerprint [--key-file F.pub | --public-key "ssh-ed25519 ..."]
                workbench keys account list   --provider P
                workbench keys account add    --provider P --name N [--key-file F.pub | --public-key "..."]   (write)
                workbench keys account rename <key-id> --provider P --name N   (write)
                workbench keys account remove <key-id> --provider P --force    (destructive; servers keep the key)
                workbench keys server list      --host user@host [--ssh-opt "-p 2222"]
                workbench keys server add       --host user@host [--key-file F.pub | --public-key "..."]   (write)
                workbench keys server remove <n|SHA256:fp|comment> --host user@host [--force]   (write)
                workbench keys server fix-perms --host user@host   (write)

                Providers: digitalocean, vultr, hetzner, linode, scaleway, plus "extra_providers" from
                --config FILE, $VSW_KEYS_CONFIG, $VPSKEYS_CONFIG or ~/.config/vps-server-workbench/keys.json.
                The key file defaults to ~/.ssh/id_ed25519.pub; private keys are never read.
                Server edits: the current session's key can't be removed; the last key, your own local keys,
                or an unknown session key need --force; the file is backed up, written atomically, read back,
                and a fresh login is tested (the backup is restored if it fails).
                TXT.self::COMMON,
            'health' => <<<'TXT'
                workbench health <url> [<url>...] [--expect 200] [--contains TEXT] [--max-ms 1500]

                GETs each URL (no auth, no redirects) and checks status, body and latency.
                Exit 0 when all pass, 1 when any fails. Use it after a deploy or from cron.
                TXT.self::COMMON,
            default => <<<'TXT'
                workbench — VPS and platform tooling (vps-server-workbench)

                Platform APIs (PHP core):
                  workbench do ...           DigitalOcean: droplets, snapshots, firewalls, uptime checks
                  workbench cf ...           Cloudflare: zones, DNS records
                  workbench ploi ...         Ploi: servers, sites, deploy scripts, daemons, deploys
                  workbench keys ...         SSH keys: provider accounts (DO, Vultr, Hetzner, Linode, Scaleway) and servers
                  workbench health <url>     check health endpoints
                  workbench gcp ...          Google Compute Engine: instances, snapshots, firewalls
                  workbench credentials      which credentials are configured (never shows values)
                  workbench help <area>      commands for one area
                TXT.self::COMMON,
        };
    }
}
