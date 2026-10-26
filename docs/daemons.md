# Ploi daemons (Supervisor)

Create two daemons in **Ploi > Server > Daemons**. Ploi runs them under
Supervisor and restarts them if they exit; `php artisan queue:restart` in the
deploy script makes workers pick up each new release.

| Field | Queue worker | Scheduler |
|---|---|---|
| Command | `php artisan queue:work` (add your own flags, e.g. `--tries`) | `php artisan schedule:work` |
| Processes | 1 (raise for throughput) | 1 (always exactly one) |
| Directory | `/home/ploi/<site>/src` | `/home/ploi/<site>/src` |
| Environment file | *(empty)* | *(empty)* |
| System user | `ploi` | `ploi` |

- **Directory** is the Laravel root of the *current* release (`/home/ploi/<site>`
  is a symlink to it on zero-downtime sites; drop `/src` if the app is at the
  repo root). The app reads its settings from the symlinked shared `.env`, which
  is why **Environment file** stays empty.
- With `schedule:work` running as a daemon, **don't** also enable Ploi's
  scheduler cron (`schedule:run`), or tasks run twice.
