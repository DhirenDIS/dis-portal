/**
 * Database access, scoped to the signed-in user.
 *
 * Everything the portal reads or writes for an operator goes through asUser().
 * It opens a transaction, switches to the `authenticated` role and sets
 * app.user_id with SET LOCAL, which is what makes every RLS policy in
 * db/migrations/0002_rls.sql apply. SET LOCAL dies with the transaction, so
 * identity can never leak between pooled requests.
 *
 * Two things will silently disable all of it:
 *
 *   1. Connecting as a superuser or as the tables' owner. Postgres bypasses
 *      RLS for both, so DATABASE_URL must point at `portal_app`, never at
 *      Railway's default `postgres` user. See db/README.md.
 *   2. Querying through `pool` directly for business data. Don't. That runs
 *      with no app.user_id, and policies will return nothing (or, as the
 *      owner, everything).
 */

import { Pool, type PoolClient } from "pg";

const UUID =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

declare global {
  // Next dev reloads modules; keep one pool rather than leaking a new one per reload.
  var __portalPool: Pool | undefined;
}

function makePool(): Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error(
      "DATABASE_URL is not set. On Railway, set it on the app service to the " +
        "portal_app connection string (not the Postgres service's own DATABASE_URL, " +
        "which is the superuser and bypasses RLS).",
    );
  }

  // Railway's internal network presents a certificate that does not validate
  // against public roots; traffic stays inside the private network. Set
  // PGSSL_STRICT=1 to demand verification (e.g. when going over the internet).
  const strict = process.env.PGSSL_STRICT === "1";

  return new Pool({
    connectionString,
    max: Number(process.env.PGPOOL_MAX ?? 10),
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    ssl: strict ? { rejectUnauthorized: true } : { rejectUnauthorized: false },
  });
}

export const pool: Pool = global.__portalPool ?? makePool();
if (process.env.NODE_ENV !== "production") global.__portalPool = pool;

/**
 * Run `fn` as the given user, inside one transaction, with RLS in force.
 * Commits on success, rolls back on any thrown error.
 */
export async function asUser<T>(
  userId: string,
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> {
  if (!UUID.test(userId)) {
    // Not a SQL-injection guard - the value is parameterised - but a bad id
    // would otherwise silently produce an empty result set that looks like
    // "this operator has no data" rather than a bug.
    throw new Error("asUser: userId must be a uuid, got " + JSON.stringify(userId));
  }

  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query("set local role authenticated");
    await client.query("select set_config('app.user_id', $1, true)", [userId]);
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (err) {
    try {
      await client.query("rollback");
    } catch {
      /* connection may already be broken; the release below discards it */
    }
    throw err;
  } finally {
    // Belt and braces: if the transaction ended abnormally the role could
    // otherwise persist on a pooled connection.
    try {
      await client.query("reset role");
    } catch {
      /* ignore */
    }
    client.release();
  }
}

/**
 * Server-only access with no user context, for things that exist before anyone
 * is signed in: Auth.js verification tokens and sessions.
 *
 * Never use this for franchise or order data - it has no app.user_id, so RLS
 * would either hide everything or, if the role were ever over-privileged,
 * expose everything.
 */
export async function asService<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    return await fn(client);
  } finally {
    client.release();
  }
}

/** Convenience: one query as a user, returning rows. */
export async function queryAsUser<R extends Record<string, unknown>>(
  userId: string,
  sql: string,
  params: unknown[] = [],
): Promise<R[]> {
  return asUser(userId, async (c) => (await c.query(sql, params)).rows as R[]);
}
