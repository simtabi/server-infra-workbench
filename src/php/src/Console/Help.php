<?php

declare(strict_types=1);

namespace Simtabi\ServerInfraWorkbench\Console;

final class Help
{
    private const string COMMON = <<<'TXT'


        Flags: --json  machine-readable output     --dry-run, -n  show the plan, send nothing
               --yes, -y  skip the prompt on writes --force  also required for destructive writes
               --verbose  log requests (redacted) to stderr
               --quiet, -q  no progress on long waits (SIWO_PROGRESS=auto|tty|plain|off, NO_COLOR)
        Credentials: env vars or ~/.config/server-infra-workbench/credentials (chmod 600). See: siwo credentials
        TXT;

    public static function for(string $area): string
    {
        return match ($area) {
            'do', 'digitalocean' => <<<'TXT'
                siwo do droplets [--tag T]                 list droplets
                siwo do droplet <id>                       one droplet
                siwo do snapshots [<droplet-id>]           list snapshots (all, or one droplet's)
                siwo do snapshot <droplet-id> [--name N] [--wait] [--timeout S]   take a snapshot (write)
                siwo do snapshot-delete <snapshot-id> --force   delete a snapshot (destructive)
                siwo do account                            check the token
                siwo do resize <droplet-id> --size S [--disk] [--timeout S]   shutdown, resize, power on (write;
                        downtime; --disk is permanent and needs --force). Snapshot first.
                siwo do alerts [list]                      monitoring alert policies
                siwo do alerts standard --email a@x (--droplet ID[,ID] | --tag T)   cpu>85% 10m, memory>90% 10m,
                        disk>85% 5m; creates only the missing ones (write)
                siwo do alerts create --type cpu|memory|disk|load1|load5|load15|bandwidth-out --value N
                        [--window 5m|10m|30m|1h] [--below] --email a@x (--droplet ID | --tag T)   (write)
                siwo do alerts delete <uuid> --force       (destructive)
                siwo do droplet-create <name> --region R --size S --ssh-keys ID[,ID] [--image I|latest]
                        [--vpc UUID] [--tag T[,T]] [--backups] [--user-data FILE]   create a droplet (write; idempotent by name;
                        image: --image, else SIWO_DROPLET_IMAGE, else ubuntu-26-04-x64, the newest Ubuntu LTS;
                        "latest" asks the API for the newest Ubuntu LTS)
                siwo do firewalls                          cloud firewalls (WORLD-OPEN marks non-web ports open to all)
                siwo do firewall-apply db|web --vpc VPC_ID|CIDR [--name N] [--ssh-from CIDR[,CIDR]]
                        [--ports 5432,6379] [--droplet ID[,ID]] [--tag T]   create or update a preset (write)
                siwo do firewall-delete <firewall-id> --force   (destructive)
                siwo do uptime [checks]                    uptime checks
                siwo do uptime state <check-id>            up/down per region
                siwo do uptime check-create <name> <url> [--type https|http|ping] [--regions us_east,eu_west]   (write)
                siwo do uptime check-delete <check-id> --force   (destructive)
                siwo do uptime alerts <check-id>
                siwo do uptime alert-create <check-id> down|down_global|latency|ssl_expiry --email a@x[,b@y]
                        [--threshold N] [--period 2m|5m|...|1h] [--name N]   (write)
                siwo do regions | sizes [--region R]        catalog (slugs for --region / --size)
                siwo do droplet-delete <id> --force        delete a droplet (destructive; snapshot first)
                siwo do power <id> power_on|shutdown|reboot|power_cycle|power_off   (write; power_off/cycle need --force)
                siwo do volumes [list] [--region R]
                siwo do volumes create <name> --region R --size-gb N [--filesystem ext4|xfs] [--tag T]   (write)
                siwo do volumes attach|detach <volume-id> --droplet ID [--wait]   (write)
                siwo do volumes resize <volume-id> --size-gb N   grow only (write; can't shrink, needs --force)
                siwo do volumes delete <volume-id> --force  (destructive)
                siwo do vpcs [list] [--region R] | members <vpc-id>
                siwo do vpcs create <name> --region R [--ip-range CIDR] [--description D]   (write)
                siwo do vpcs default <vpc-id>              make it the region default (write)
                siwo do vpcs delete <vpc-id> --force       refuses the default VPC or one with members
                siwo do spaces-keys [list]
                siwo do spaces-keys create <name> --bucket B[,B] [--permission read|readwrite] --out FILE
                        (write; the secret is written to FILE, mode 600, never printed. --permission fullaccess
                        without --bucket covers every bucket and needs --force)
                siwo do spaces-keys delete <access-key> --force
                siwo do domains [list] | create <domain> [--ip IP] | delete <domain> --force
                siwo do dns list <domain> [--type A] [--name N]
                siwo do dns upsert <domain> <type> <name> <data> [--ttl 1800] [--priority P]   (write)
                siwo do dns delete <domain> <record-id> --force
                siwo do reserved-ips [list] | create (--region R | --droplet ID) | assign <ip> --droplet ID
                        | unassign <ip> | delete <ip> --force   (writes)
                siwo do projects [list] | resources <project-id> | assign <project-id> <urn>...   (assign is a write)
                siwo do tags [list] | create <tag> | attach|detach <tag> <id>... [--type droplet|volume|...] | delete <tag> --force
                siwo do ssh-keys list|add|rename|remove ...   same as: siwo keys account ... --provider digitalocean
                TXT.self::COMMON,
            'cf', 'cloudflare' => <<<'TXT'
                siwo cf verify                             check the token
                siwo cf zones | zone <zone>                list zones (a zone is its id or name)
                siwo cf dns list <zone> [--type A] [--name N]
                siwo cf dns upsert <zone> <type> <name> <content> [--ttl 1] [--proxied] [--priority P] [--comment C]   (write)
                siwo cf dns delete <zone> <record-id> --force   (destructive)
                siwo cf settings list <zone>               ssl, always_use_https, min_tls_version, tls_1_3, ...
                siwo cf settings set <zone> <setting> <value>   (write; weakening one needs --force)
                siwo cf ssl <zone> [off|flexible|full|strict]   show or set the SSL mode (use strict)
                siwo cf origin-certs list <zone>
                siwo cf origin-certs create <zone> --hostnames a.example,*.example [--validity 5475] --out FILE
                        (write; key + CSR made locally; key to FILE, mode 600; certificate to FILE.crt)
                siwo cf origin-certs revoke <zone> <cert-id> --force
                siwo cf purge <zone> --files URL[,URL]     (write; up to 30 URLs)   | --everything --force
                siwo cf firewall rules <zone>              IP access rules
                siwo cf firewall add <zone> block|challenge|managed_challenge|allow <value> [--target ip|ip_range|asn|country] [--comment C]
                siwo cf firewall delete <zone> <rule-id> --force
                siwo cf firewall waf <zone>                custom WAF rules (read-only)
                TXT.self::COMMON,
            'ploi' => <<<'TXT'
                siwo ploi servers                          list servers
                siwo ploi server <server-id>               one server
                siwo ploi sites <server-id>                sites on a server
                siwo ploi deploy <server-id> <site-id>     run the site's deploy script (write)
                siwo ploi site-create <server-id> <domain> [--web-directory /public] [--project-type laravel] [--user ploi]   (write)
                siwo ploi site-delete <server-id> <site-id> --force   (destructive)
                siwo ploi deploy-script <server-id> <site-id>         print the deploy script
                siwo ploi deploy-script-set <server-id> <site-id> --file deploy.sh   replace it (write; no-op if identical)
                siwo ploi daemons <server-id>
                siwo ploi daemon-create <server-id> --command "php artisan queue:work" [--user ploi] [--processes 1] [--directory D]   (write)
                siwo ploi daemon-delete <server-id> <daemon-id> --force   (destructive)
                siwo ploi server-restart <server-id> --force   (destructive; downtime)
                siwo ploi site <server-id> <site-id>
                siwo ploi crons <server-id>
                siwo ploi cron-create <server-id> --command C --frequency "* * * * *" [--user ploi]   (write)
                siwo ploi cron-delete <server-id> <cron-id> --force
                siwo ploi databases <server-id>
                siwo ploi database-create <server-id> <name> [--user U --out FILE] [--site ID] [--description D]
                        (write; with --user a password is generated locally and written to FILE, mode 600)
                siwo ploi database-delete <server-id> <database-id> --force
                siwo ploi certs <server-id> <site-id>
                siwo ploi cert-create <server-id> <site-id> --domain a.example[,www.a.example]   Let's Encrypt (write;
                        DNS must already point at the server)
                siwo ploi cert-delete <server-id> <site-id> <cert-id> --force
                TXT.self::COMMON,
            'gcp', 'gcloud' => <<<'TXT'
                siwo gcp instances [--zone Z] [--project P]
                siwo gcp instance show <name> --zone Z
                siwo gcp instance create <name> --zone Z [--size e2-small] [--image I] [--disk-gb 20] [--tag T] [--network N]
                        (write; OS Login, Shielded VM, no service-account scopes; idempotent by name)
                siwo gcp instance start|stop <name> --zone Z [--wait]   (write)
                siwo gcp instance reset <name> --zone Z --force    (destructive; hard reset)
                siwo gcp instance delete <name> --zone Z --force   (destructive)
                siwo gcp snapshots [--project P]
                siwo gcp snapshot <zone> <disk> [--name N] [--wait]   snapshot a disk (write)
                siwo gcp snapshot-delete <snapshot> --force
                siwo gcp firewalls [--project P]           WORLD-OPEN marks rules open to 0.0.0.0/0
                siwo gcp firewall-create <name> --allow tcp:22,tcp:443 --source-ranges CIDR[,CIDR] [--target-tags T]
                        [--network default] [--priority 1000] [--description D]   (write; world-open non-web ports need --force)
                siwo gcp firewall-delete <name> --force
                siwo gcp dns [zones] | zone-create <domain> [--name N] | zone-delete <zone> --force
                siwo gcp dns list <zone> [--type A] [--name N]
                siwo gcp dns upsert <zone> <type> <name> <value>... [--ttl 300]   (write; one atomic change)
                siwo gcp dns delete <zone> <type> <name> --force
                siwo gcp buckets [list] | show <bucket> | objects <bucket> [--prefix P] [--limit 100]
                siwo gcp buckets create <bucket> [--location US] [--storage-class STANDARD] [--retention-days N]
                        (write; uniform access, public access prevented, versioning on; --retention-days deletes objects older than N days)
                siwo gcp buckets delete <bucket> --force   (destructive; must be empty)
                TXT.self::COMMON,
            'github', 'gh' => <<<'TXT'
                siwo github whoami | rate-limit
                siwo github repos [--org O] [--limit 100]
                siwo github repo|workflows --repo owner/name
                siwo github runs --repo R [--workflow ci.yml] [--branch B] [--status S] [--limit 20]
                siwo github run <run-id> --repo R [--wait] [--timeout S]
                siwo github dispatch <workflow> --repo R --ref BRANCH [--inputs k=v,k=v]   (write)
                siwo github rerun|cancel <run-id> --repo R   (write)
                siwo github secrets [list] --repo R [--env E]
                siwo github secrets set <NAME> --repo R [--env E] (--value-file FILE | value on stdin)
                        (write; sealed locally with the repo public key; never taken from argv, never printed)
                siwo github secrets delete <NAME> --repo R [--env E] --force
                siwo github deploy-keys [list] --repo R
                siwo github deploy-keys add --repo R --title T --key-file K.pub [--write]   (read-only unless --write, which needs --force)
                siwo github deploy-keys delete <key-id> --repo R --force
                siwo github releases [list] | latest --repo R
                siwo github releases create <tag> --repo R [--target SHA|branch] [--title T] [--notes-file F] [--draft] [--prerelease]
                siwo github releases delete <release-id> --repo R --force
                Alias: siwo gh ...
                TXT.self::COMMON,
            'keys' => <<<'TXT'
                siwo keys                                  interactive menu (account and server keys)
                siwo keys providers                        providers, and which have credentials
                siwo keys fingerprint [--key-file F.pub | --public-key "ssh-ed25519 ..."]
                siwo keys account list   --provider P
                siwo keys account add    --provider P --name N [--key-file F.pub | --public-key "..."]   (write)
                siwo keys account rename <key-id> --provider P --name N   (write)
                siwo keys account remove <key-id> --provider P --force    (destructive; servers keep the key)
                siwo keys server list      --host user@host [--ssh-opt "-p 2222"]
                siwo keys server add       --host user@host [--key-file F.pub | --public-key "..."]   (write)
                siwo keys server remove <n|SHA256:fp|comment> --host user@host [--force]   (write)
                siwo keys server fix-perms --host user@host   (write)

                Providers: digitalocean, vultr, hetzner, linode, scaleway, plus "extra_providers" from
                --config FILE, $SIWO_KEYS_CONFIG, $VPSKEYS_CONFIG or ~/.config/server-infra-workbench/keys.json.
                The key file defaults to ~/.ssh/id_ed25519.pub; private keys are never read.
                Server edits: the current session's key can't be removed; the last key, your own local keys,
                or an unknown session key need --force; the file is backed up, written atomically, read back,
                and a fresh login is tested (the backup is restored if it fails).
                TXT.self::COMMON,
            'health' => <<<'TXT'
                siwo health <url> [<url>...] [--expect 200] [--contains TEXT] [--max-ms 1500]

                GETs each URL (no auth, no redirects) and checks status, body and latency.
                Exit 0 when all pass, 1 when any fails. Use it after a deploy or from cron.
                TXT.self::COMMON,
            default => <<<'TXT'
                siwo — server infrastructure and platform tooling (server-infra-workbench)

                Platform APIs (PHP core):
                  siwo do ...           DigitalOcean: droplets, volumes, VPCs, firewalls, DNS, Spaces keys, IPs, projects, alerts
                  siwo cf ...           Cloudflare: zones, DNS, SSL mode, origin certs, cache purge, firewall
                  siwo gcp ...          Google Cloud: instances, firewalls, snapshots, Cloud DNS, Cloud Storage
                  siwo github ...       GitHub: repos, Actions runs/dispatch, secrets, deploy keys, releases
                  siwo ploi ...         Ploi: servers, sites, deploys, daemons, cron, databases, SSL
                  siwo keys ...         SSH keys: provider accounts (DO, Vultr, Hetzner, Linode, Scaleway) and servers
                  siwo health <url>     check health endpoints
                  siwo credentials      which credentials are configured (never shows values)
                  siwo help <area>      commands for one area
                TXT.self::COMMON,
        };
    }
}
