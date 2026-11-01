# db.py - one async connection pool per worker process, opened at startup, closed at shutdown.
# psycopg 3 (pip install "psycopg[binary,pool]"). The conninfo is empty on purpose: libpq takes host, port,
# database, user, sslmode from the PG* variables and the password from PGPASSFILE (600), so no secret is ever
# in code, a URL, or a traceback.
from contextlib import asynccontextmanager

from fastapi import FastAPI
from psycopg_pool import AsyncConnectionPool

pool = AsyncConnectionPool(conninfo="", min_size=1, max_size=5, open=False, check=AsyncConnectionPool.check_connection)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await pool.open(wait=True, timeout=10)  # fail the worker's start, not the first request
    yield
    await pool.close()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)  # no public /docs in production


@app.get("/healthz")
async def healthz():
    async with pool.connection() as conn:
        await conn.execute("SELECT 1")
    return {"ok": True}
