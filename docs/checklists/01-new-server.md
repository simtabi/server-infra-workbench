# 01. New server

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Pick a profile and generate the client config | `bin/workbench configure --client <client>` (or `--profile dev-budget`) | `local/<client>/workbench.conf` exists; the summary has no errors | one place records size, region, engines and backups; RAM and region checks run before you spend money |
| 2 | Check sizes and prices | `bin/workbench plans --regions <region>` | the plan you want is listed for that region | not every size is in every region |
| 3 | Create the droplet in the **same region and VPC** as its peers | `bin/workbench do droplet-create <name> --region <r> --size <s> --ssh-keys <id> --vpc <uuid> [--image ubuntu-26-04-x64] --dry-run`, then without `--dry-run` | `bin/workbench do droplets` shows it with a PRIVATE IP in your VPC | VPCs are per region: a server elsewhere can't reach the DB privately ([cross-region](../cross-region.md)) |
| 4 | Note public and private IPs in `local/<client>/` | edit `local/<client>/README.md` | IPs match `do droplets` | the wrong IP in an `.env` was a real outage |
| 5 | SSH alias and key login | [set up SSH access](../recipes/set-up-ssh-access.md) | `ssh <alias> 'hostname; ip -4 -br addr'` | every tool connects by alias; check `eth1` is the VPC address |
| 6 | Keep a way back in | DO console URL in your notes; `bin/workbench keys server list --host <alias>` | console login tested once | key mistakes happen; the console bypasses SSH |
| 7 | Initialize | `bin/workbench server init --host <alias> --role db\|web --swap 2G --dry-run`, then `--yes` | re-running the plan shows only `ok` lines | timezone, swap, base packages, Docker (db), updates, hardening; Ploi-aware |
| 8 | First inventory | `bin/workbench server inventory --host <alias> --pull --client <client>` | files under `local/<client>/inventory/<alias>/` | a baseline to diff against after every change |
| 9 | Tag it in DO | DO panel: tags `db`/`web`, env | `bin/workbench do droplets --tag db` | firewalls and alerts target tags |
