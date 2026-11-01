# gunicorn.conf.py - read by `gunicorn -c gunicorn.conf.py` (the Ploi daemon command in README.md).
import multiprocessing
import os

bind = "127.0.0.1:" + os.environ.get("PORT", "8000")  # loopback only: Nginx is the public side
workers = int(os.environ.get("WEB_CONCURRENCY", multiprocessing.cpu_count() * 2 + 1))
worker_class = "sync"              # gthread or uvicorn workers only if the app needs them
max_requests = 1000                # recycle workers: a slow leak never takes the box down
max_requests_jitter = 100
timeout = 30
graceful_timeout = 30
forwarded_allow_ips = "127.0.0.1"  # trust X-Forwarded-* from Nginx only
accesslog = "-"
errorlog = "-"
