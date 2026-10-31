# Checklists

Copy a checklist into the ticket or notes for the job and tick it there. Every command is plan-first: run it
with `--dry-run` (or read its plan) before `--yes`. Commands assume the manager is at
`/root/docker-db-server-manager.sh` and the workbench is checked out on your workstation.

| Checklist | Use it when |
|---|---|
| [New DB server](new-db-server.md) | building a database droplet from scratch |
| [New web server](new-web-server.md) | adding a Ploi web server for a Laravel site |
| [Manager upgrade](manager-upgrade.md) | rolling a new DB manager version onto a live server |
| [Pre-launch](pre-launch.md) | before real users or paying customers arrive |
| [Monthly restore drill](monthly-restore-drill.md) | proving the backups restore, every month |
| [Recover from an SSH lockout](../recipes/recover-ssh-lockout.md) | you can't log in (a recipe, but used like a checklist) |
