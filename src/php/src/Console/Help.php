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
                workbench do regions | sizes [--region R]        catalog (slugs for --region / --size)
                workbench do droplet-delete <id> --force        delete a droplet (destructive; snapshot first)
                workbench do power <id> power_on|shutdown|reboot|power_cycle|power_off   (write; power_off/cycle need --force)
                workbench do volumes [list] [--region R]
                workbench do volumes create <name> --region R --size-gb N [--filesystem ext4|xfs] [--tag T]   (write)
                workbench do volumes attach|detach <volume-id> --droplet ID [--wait]   (write)
                workbench do volumes resize <volume-id> --size-gb N   grow only (write; can't shrink, needs --force)
                workbench do volumes delete <volume-id> --force  (destructive)
                workbench do vpcs [list] [--region R] | members <vpc-id>
                workbench do vpcs create <name> --region R [--ip-range CIDR] [--description D]   (write)
                workbench do vpcs default <vpc-id>              make it the region default (write)
                workbench do vpcs delete <vpc-id> --force       refuses the default VPC or one with members
                workbench do spaces-keys [list]
                workbench do spaces-keys create <name> --bucket B[,B] [--permission read|readwrite] --out FILE
                        (write; the secret is written to FILE, mode 600, never printed. --permission fullaccess
                        without --bucket covers every bucket and needs --force)
                workbench do spaces-keys delete <access-key> --force
                workbench do domains [list] | create <domain> [--ip IP] | delete <domain> --force
                workbench do dns list <domain> [--type A] [--name N]
                workbench do dns upsert <domain> <type> <name> <data> [--ttl 1800] [--priority P]   (write)
                workbench do dns delete <domain> <record-id> --force
                workbench do reserved-ips [list] | create (--region R | --droplet ID) | assign <ip> --droplet ID
                        | unassign <ip> | delete <ip> --force   (writes)
                workbench do projects [list] | resources <project-id> | assign <project-id> <urn>...   (assign is a write)
                workbench do tags [list] | create <tag> | attach|detach <tag> <id>... [--type droplet|volume|...] | delete <tag> --force
                workbench do ssh-keys list|add|rename|remove ...   same as: workbench keys account ... --provider digitalocean
                TXT.self::COMMON,
            'cf', 'cloudflare' => <<<'TXT'
                workbench cf verify                             check the token
                workbench cf zones | zone <zone>                list zones (a zone is its id or name)
                workbench cf dns list <zone> [--type A] [--name N]
                workbench cf dns upsert <zone> <type> <name> <content> [--ttl 1] [--proxied] [--priority P] [--comment C]   (write)
                workbench cf dns delete <zone> <record-id> --force   (destructive)
                workbench cf settings list <zone>               ssl, always_use_https, min_tls_version, tls_1_3, ...
                workbench cf settings set <zone> <setting> <value>   (write; weakening one needs --force)
                workbench cf ssl <zone> [off|flexible|full|strict]   show or set the SSL mode (use strict)
                workbench cf origin-certs list <zone>
                workbench cf origin-certs create <zone> --hostnames a.example,*.example [--validity 5475] --out FILE
                        (write; key + CSR made locally; key to FILE, mode 600; certificate to FILE.crt)
                workbench cf origin-certs revoke <zone> <cert-id> --force
                workbench cf purge <zone> --files URL[,URL]     (write; up to 30 URLs)   | --everything --force
                workbench cf firewall rules <zone>              IP access rules
                workbench cf firewall add <zone> block|challenge|managed_challenge|allow <value> [--target ip|ip_range|asn|country] [--comment C]
                workbench cf firewall delete <zone> <rule-id> --force
                workbench cf firewall waf <zone>                custom WAF rules (read-only)
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
                workbench ploi server-restart <server-id> --force   (destructive; downtime)
                workbench ploi site <server-id> <site-id>
                workbench ploi crons <server-id>
                workbench ploi cron-create <server-id> --command C --frequency "* * * * *" [--user ploi]   (write)
                workbench ploi cron-delete <server-id> <cron-id> --force
                workbench ploi databases <server-id>
                workbench ploi database-create <server-id> <name> [--user U --out FILE] [--site ID] [--description D]
                        (write; with --user a password is generated locally and written to FILE, mode 600)
                workbench ploi database-delete <server-id> <database-id> --force
                workbench ploi certs <server-id> <site-id>
                workbench ploi cert-create <server-id> <site-id> --domain a.example[,www.a.example]   Let's Encrypt (write;
                        DNS must already point at the server)
                workbench ploi cert-delete <server-id> <site-id> <cert-id> --force
                TXT.self::COMMON,
            'gcp', 'gcloud' => <<<'TXT'
                workbench gcp instances [--zone Z] [--project P]
                workbench gcp instance show <name> --zone Z
                workbench gcp instance create <name> --zone Z [--size e2-small] [--image I] [--disk-gb 20] [--tag T] [--network N]
                        (write; OS Login, Shielded VM, no service-account scopes; idempotent by name)
                workbench gcp instance start|stop <name> --zone Z [--wait]   (write)
                workbench gcp instance reset <name> --zone Z --force    (destructive; hard reset)
                workbench gcp instance delete <name> --zone Z --force   (destructive)
                workbench gcp snapshots [--project P]
                workbench gcp snapshot <zone> <disk> [--name N] [--wait]   snapshot a disk (write)
                workbench gcp snapshot-delete <snapshot> --force
                workbench gcp firewalls [--project P]           WORLD-OPEN marks rules open to 0.0.0.0/0
                workbench gcp firewall-create <name> --allow tcp:22,tcp:443 --source-ranges CIDR[,CIDR] [--target-tags T]
                        [--network default] [--priority 1000] [--description D]   (write; world-open non-web ports need --force)
                workbench gcp firewall-delete <name> --force
                workbench gcp dns [zones] | zone-create <domain> [--name N] | zone-delete <zone> --force
                workbench gcp dns list <zone> [--type A] [--name N]
                workbench gcp dns upsert <zone> <type> <name> <value>... [--ttl 300]   (write; one atomic change)
                workbench gcp dns delete <zone> <type> <name> --force
                workbench gcp buckets [list] | show <bucket> | objects <bucket> [--prefix P] [--limit 100]
                workbench gcp buckets create <bucket> [--location US] [--storage-class STANDARD] [--retention-days N]
                        (write; uniform access, public access prevented, versioning on; --retention-days deletes objects older than N days)
                workbench gcp buckets delete <bucket> --force   (destructive; must be empty)
                TXT.self::COMMON,
            'github', 'gh' => <<<'TXT'
                workbench github whoami | rate-limit
                workbench github repos [--org O] [--limit 100]
                workbench github repo|workflows --repo owner/name
                workbench github runs --repo R [--workflow ci.yml] [--branch B] [--status S] [--limit 20]
                workbench github run <run-id> --repo R [--wait] [--timeout S]
                workbench github dispatch <workflow> --repo R --ref BRANCH [--inputs k=v,k=v]   (write)
                workbench github rerun|cancel <run-id> --repo R   (write)
                workbench github secrets [list] --repo R [--env E]
                workbench github secrets set <NAME> --repo R [--env E] (--value-file FILE | value on stdin)
                        (write; sealed locally with the repo public key; never taken from argv, never printed)
                workbench github secrets delete <NAME> --repo R [--env E] --force
                workbench github deploy-keys [list] --repo R
                workbench github deploy-keys add --repo R --title T --key-file K.pub [--write]   (read-only unless --write, which needs --force)
                workbench github deploy-keys delete <key-id> --repo R --force
                workbench github releases [list] | latest --repo R
                workbench github releases create <tag> --repo R [--target SHA|branch] [--title T] [--notes-file F] [--draft] [--prerelease]
                workbench github releases delete <release-id> --repo R --force
                Alias: workbench gh ...
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
                  workbench do ...           DigitalOcean: droplets, volumes, VPCs, firewalls, DNS, Spaces keys, IPs, projects, alerts
                  workbench cf ...           Cloudflare: zones, DNS, SSL mode, origin certs, cache purge, firewall
                  workbench gcp ...          Google Cloud: instances, firewalls, snapshots, Cloud DNS, Cloud Storage
                  workbench github ...       GitHub: repos, Actions runs/dispatch, secrets, deploy keys, releases
                  workbench ploi ...         Ploi: servers, sites, deploys, daemons, cron, databases, SSL
                  workbench keys ...         SSH keys: provider accounts (DO, Vultr, Hetzner, Linode, Scaleway) and servers
                  workbench health <url>     check health endpoints
                  workbench credentials      which credentials are configured (never shows values)
                  workbench help <area>      commands for one area
                TXT.self::COMMON,
        };
    }
}
