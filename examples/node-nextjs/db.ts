// lib/db.ts - server-only pool (import "server-only" keeps it out of client bundles).
// new Pool() with no options: node-postgres reads PGHOST PGPORT PGDATABASE PGUSER and, via the pgpass module,
// the password from PGPASSFILE (600). No DATABASE_URL with a password in the env, the build, or an error page.
import "server-only";
import { Pool } from "pg";

const g = globalThis as unknown as { pgPool?: Pool };
export const pool = g.pgPool ?? new Pool({ max: 5, idleTimeoutMillis: 30_000, connectionTimeoutMillis: 5_000 });
g.pgPool = pool; // one pool per process, also across dev hot reloads
