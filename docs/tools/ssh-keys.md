# SSH keys: `workbench keys` and `fixkeys.sh`

Keys live in two places, and a third tool covers the case where you are already locked out.

| Situation | Tool |
|---|---|
| Change the keys baked into **future** servers (provider dashboard) | `workbench keys account ...` |
| Change who can log in to a **running** server, while ssh still works | `workbench keys server ...` |
| **Locked out**: only the provider's web console works | [`src/shell/ssh/fixkeys.sh`](../../src/shell/ssh/fixkeys.sh), pasted into the console |

Per-host keys and `~/.ssh/config` stay with [sshmgr](../recipes/set-up-ssh-access.md); these tools only
put public keys where servers read them. Private keys are never read.

## `workbench keys`

See `workbench help keys` and the [CLI reference](cli.md). Providers: DigitalOcean, Vultr, Hetzner, Linode,
Scaleway, plus `extra_providers` in `~/.config/vps-server-workbench/keys.json`. Server edits back up the
file, write atomically, read it back and test a fresh login (restoring the backup if that fails); the
current session's key can't be removed, and the last key or your own local keys need `--force`.

## `fixkeys.sh` (console recovery)

Self-contained bash: no ssh, Python or other files. Every prompt reads from the terminal, so you can paste
the script into the console. The full walk-through is the [lockout recipe](../recipes/recover-ssh-lockout.md).

```bash
bash fixkeys.sh                                       # menu
bash fixkeys.sh add --user ploi 'ssh-ed25519 AAAA... me@laptop'
bash fixkeys.sh diagnose --user ploi                  # why does key login fail?
bash fixkeys.sh remove --user ploi SHA256:abc...      # by number or fingerprint
bash fixkeys.sh restore --user ploi                   # pick a .bak.<ts> to put back
bash fixkeys.sh --root /mnt --user root add '...'     # disk mounted from a recovery ISO
```

| Guard | How |
|---|---|
| Validation | `ssh-keygen -l` must parse the key (type + base64 shape when ssh-keygen is missing); a pasted **private** key is refused with a warning |
| Exact match | duplicates and removals compare key type + body, ignoring options (`from=...`) and comments; never a substring match |
| Right file | the effective `AuthorizedKeysFile` from `sshd -T -C user=...` (`%h`, `%u` expanded), or `--file` |
| Last key | removing it needs `EMPTY` typed; `--yes` is not enough |
| Changes | backup `<file>.bak.<ts>` (600), atomic write, 700/600 + owner (numeric uid from the server's `/etc/passwd`, so it works under `--root`), `restorecon` when SELinux is present |
| Audit | `/var/log/vps-server-workbench/audit.log` and syslog (`logger -t fixkeys`): fingerprints only |
| Restore | only `<file>.bak.*` files next to the managed file; the current file is backed up first |

`diagnose` reports: `.ssh` and file modes and owners, a group/other-writable home (sshd `StrictModes`
refuses keys), Windows line endings, unreadable lines, a `nologin` shell, a locked password (and when that
matters: `UsePAM no`), the effective `PubkeyAuthentication`, `PasswordAuthentication`, `PermitRootLogin`,
`AuthorizedKeysFile`, `StrictModes`, `AllowUsers/Groups`, `PubkeyAcceptedAlgorithms` (old `ssh-rsa`
keys), `sshd -T` errors, and the last hour's sshd refusals from the journal.

Tests: `tests/shell/smoke-server.sh` (fake root, 14 cases) and `tests/shell/server-it.sh` (as root in
Ubuntu 24.04: real chown, `ssh-keygen`, `sshd -T`, a custom `AuthorizedKeysFile /etc/ssh/keys/%u`).

## Migration from `vps-ssh-key-manager` (vpskeys)

The standalone `vps-ssh-key-manager` folder was superseded by this repo and retired (deleted) on 2026-10-31.
It had no `.env`, so there were no tokens to move. An archive is kept at
`packages/_archive/vps-ssh-key-manager-2026-10-31.tar.gz` (outside this repo).

| Old | New | Notes |
|---|---|---|
| `vpskeys.py` account keys | `workbench keys account list/add/rename/remove` | Same providers; `--json`, `--dry-run`; remove needs `--force` |
| `vpskeys.py` server keys (`serverkeys.py`) | `workbench keys server list/add/remove/fix-perms` | Adds read-back + fresh-login test with automatic restore |
| `providers.py` + `config.json` (`extra_providers`) | built-in providers + `keys.json` | **Same schema**: copy `config.json` to `~/.config/vps-server-workbench/keys.json`, or point `$VPSKEYS_CONFIG` / `$VSW_KEYS_CONFIG` at it |
| `.env` (`DIGITALOCEAN_TOKEN`, `VULTR_API_KEY`, `HCLOUD_TOKEN`, `LINODE_TOKEN`, `SCW_SECRET_KEY`, `SCW_PROJECT_ID`) | same names, in the environment or `~/.config/vps-server-workbench/credentials` (600) | Template: [`config/credentials.env.example`](../../config/credentials.env.example). Put values there yourself; no tool copies them |
| `fixkeys.sh` (menu only) | `src/shell/ssh/fixkeys.sh` 2.0 | Subcommands, `--user`, `--file`, `--root`, `FIXKEYS_TTY`, exact match, `sshd -T` + `AuthorizedKeysFile`, lock status, restore, ssh-keygen validation, audit |
| Python 3.8 + `requests` | PHP 8.4 core (no Python needed for keys) | |

### Merge checklist

- [x] Account keys for DO, Vultr, Hetzner, Linode, Scaleway, plus config-driven extra providers
- [x] Server keys over ssh: list, add (dedup by key material), remove (last key / own key guarded), fix perms
- [x] Backups, atomic writes, 700/600 and ownership on every server write
- [x] `fixkeys.sh` in the repo with the old menu and everything above; tests offline and in a container
- [x] Credentials: same variable names, env or 600 file, never logged
- [x] Docs: this page, the [lockout recipe](../recipes/recover-ssh-lockout.md), CLI reference
- [x] **You:** move token values from the old folder's `.env` into `~/.config/vps-server-workbench/credentials`:
      done, nothing to move (the old folder had no `.env`). New tokens go in that 600 file
      (`install -m 600 /dev/null ~/.config/vps-server-workbench/credentials`, then edit)
- [x] **You:** retire the old folder: done 2026-10-31 (deleted; archive kept)
