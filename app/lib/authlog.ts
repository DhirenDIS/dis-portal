/**
 * Authentication event logging and magic-link throttling.
 *
 * Both live in the database rather than in this process:
 *
 *   - the log is append-only and written by a security-definer function, so
 *     the app can record events but cannot rewrite them;
 *   - the throttle counts rows in that same log, so it holds across multiple
 *     Railway instances and survives a deploy. An in-memory limiter would
 *     allow N times the intended rate on N instances and reset on every
 *     restart.
 */

import { headers } from "next/headers";
import { asService } from "@/lib/db";

export type AuthEventKind =
  | "link_requested"
  | "link_rate_limited"
  | "link_send_failed"
  | "signin_succeeded"
  | "signout"
  | "session_revoked";

/** Caller IP and user agent, as seen behind Railway's proxy. */
export async function requestContext(): Promise<{ ip: string | null; ua: string | null }> {
  try {
    const h = await headers();
    // x-forwarded-for is a client-controlled list; the left-most entry is the
    // original client but can be spoofed. Good enough for rate limiting and
    // for an audit trail, NOT an identity or an authorisation input.
    const fwd = h.get("x-forwarded-for");
    const ip = fwd ? fwd.split(",")[0]!.trim() : h.get("x-real-ip");
    return { ip: ip || null, ua: h.get("user-agent") };
  } catch {
    return { ip: null, ua: null };
  }
}

export async function logAuthEvent(
  kind: AuthEventKind,
  opts: {
    email?: string | null;
    userId?: string | null;
    ip?: string | null;
    userAgent?: string | null;
    detail?: unknown;
  } = {},
): Promise<void> {
  try {
    await asService((c) =>
      c.query(
        "select public.log_auth_event($1::public.auth_event_kind, $2, $3, $4, $5, $6::jsonb)",
        [
          kind,
          opts.email ?? null,
          opts.userId ?? null,
          opts.ip ?? null,
          opts.userAgent ?? null,
          opts.detail === undefined ? null : JSON.stringify(opts.detail),
        ],
      ),
    );
  } catch (err) {
    // Never let logging break sign-in. A dropped event is bad; a portal that
    // refuses to authenticate because the log is unavailable is worse.
    console.error("auth event log failed:", kind, err);
  }
}

/**
 * May we send a magic link for this address from this IP?
 *
 * Fails OPEN on a database error, because failing closed would make a
 * transient fault look like a total lockout. The attempt is still logged.
 */
export async function magicLinkAllowed(
  email: string,
  ip: string | null,
): Promise<{ allowed: boolean; emailCount: number; ipCount: number }> {
  try {
    return await asService(async (c) => {
      const r = await c.query(
        "select allowed, email_count, ip_count from public.magic_link_allowed($1, $2)",
        [email, ip],
      );
      const row = r.rows[0] as
        | { allowed: boolean; email_count: number; ip_count: number }
        | undefined;
      return {
        allowed: row?.allowed ?? true,
        emailCount: Number(row?.email_count ?? 0),
        ipCount: Number(row?.ip_count ?? 0),
      };
    });
  } catch (err) {
    console.error("rate-limit check failed, allowing:", err);
    return { allowed: true, emailCount: 0, ipCount: 0 };
  }
}
