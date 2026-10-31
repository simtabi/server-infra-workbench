# Ploi daemons (Supervisor)

Create two daemons on the server's **Daemons** page in Ploi. Ploi runs them under
Supervisor and restarts them if they exit; `php artisan queue:restart` in the
deploy script makes workers pick up each new release.

| Field | Queue worker | Scheduler |
|---|---|---|
| Command | `php artisan queue:work` (add your own flags, e.g. `--tries`) | `php artisan schedule:work` |
| Processes | 1 (raise for throughput) | 1 (always exactly one) |
| Directory | `/home/ploi/<site>/src` | `/home/ploi/<site>/src` |
| Environment file | *(empty)* | *(empty)* |
| System user | `ploi` | `ploi` |

- **Directory** is the Laravel root of the live release: the site folder plus
  `APP_SUBDIR` (drop `/src` if the app is at the repo root). On a zero-downtime
  site, use the path Ploi shows for the site's current release if it differs. The app reads its settings from the symlinked shared `.env`, which
  is why **Environment file** stays empty.
- With `schedule:work` running as a daemon, **don't** also enable Ploi's
  scheduler cron (`schedule:run`), or tasks run twice.
