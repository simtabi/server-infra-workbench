# 11. Decommission

| # | Step | Command | Verify | Why |
|---|---|---|---|---|
| 1 | Final backup, off-site | `M backup`; `M offsite verify` | verify passes | the last copy of the data |
| 2 | Final snapshot | `bin/workbench do snapshot <id> --name final-<name> --wait` | `do snapshots <id>` | cheap insurance for a month |
| 3 | Final inventory | `bin/workbench server inventory --host <alias> --pull --client <client>` | files pulled | a record of what ran there |
| 4 | Retire an environment only | `M drop-db <app>_<env> [--force-prod]` (soft: renamed to `__trash_<ts>`), later `M purge-trash` | `M env-list` | soft drop leaves `TRASH_DAYS` to change your mind |
| 5 | Remove monitoring | `bin/workbench do uptime check-delete <id> --force`; `do alerts delete <uuid> --force` | lists empty for it | stale alerts train you to ignore alerts |
| 6 | Remove its keys and firewall rules | `bin/workbench keys server list`; `do firewall-delete <id> --force`; `net wireguard remove --host <alias>` | nothing points at it | old trust relationships are attack surface |
| 7 | Remove from Ploi and DNS | Ploi panel; `bin/workbench cf dns delete ...` | DNS no longer resolves to it | dangling DNS can be taken over |
| 8 | Destroy the droplet | DO panel (deliberately manual) | gone from `do droplets` | the workbench never deletes droplets |
| 9 | Update notes | `local/<client>/README.md` | IPs removed | the next person trusts these notes |
