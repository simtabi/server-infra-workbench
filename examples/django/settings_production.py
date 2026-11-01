# settings_production.py - the production part of a Django settings module (import it last, or point
# DJANGO_SETTINGS_MODULE at a module that does `from .base import *` and then this).
# Every value comes from the environment that with-env.sh exports from the shared .env. No password here:
# libpq reads it from PGPASSFILE (a 600 file), so it never sits in settings, logs or error pages.
import os

SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]  # KeyError at boot beats running with a default key
DEBUG = os.environ.get("DJANGO_DEBUG", "0") == "1"
ALLOWED_HOSTS = os.environ["DJANGO_ALLOWED_HOSTS"].split(",")
CSRF_TRUSTED_ORIGINS = ["https://" + h for h in ALLOWED_HOSTS]

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",  # psycopg 3 (pip install "psycopg[binary]")
        "NAME": os.environ["PGDATABASE"],
        "USER": os.environ["PGUSER"],
        "HOST": os.environ["PGHOST"],
        "PORT": os.environ["PGPORT"],
        "OPTIONS": {
            "passfile": os.environ["PGPASSFILE"],
            "sslmode": os.environ.get("PGSSLMODE", "prefer"),
        },
        # persistent connections, checked before reuse: fewer TCP + auth round trips to the DB droplet
        "CONN_MAX_AGE": 60,
        "CONN_HEALTH_CHECKS": True,
    }
}
if os.environ.get("PGSSLROOTCERT"):
    DATABASES["default"]["OPTIONS"]["sslrootcert"] = os.environ["PGSSLROOTCERT"]

# Nginx terminates TLS and sets X-Forwarded-Proto (examples/_shared/nginx-proxy.conf)
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_SSL_REDIRECT = False  # Nginx already redirects; doing it twice loops behind some proxies
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_HSTS_SECONDS = 31536000

STATIC_ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "staticfiles")
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},  # Supervisor keeps the daemon's log
    "root": {"handlers": ["console"], "level": "WARNING"},
}
