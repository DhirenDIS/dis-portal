#!/usr/bin/env python
"""
Read-only status report. Run inside Railway.

Prints recent authentication events, who has portal access, and order counts.
Deliberately never selects a session token or a password - this output lands in
Railway's deploy logs, which is not a place for bearer credentials.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apply import load_url, parse_url, connect   # noqa: E402


def table(cur, title, sql, params=()):
    print("\n=== %s ===" % title)
    try:
        cur.execute(sql, params)
    except Exception as exc:                       # noqa: BLE001
        print("  query failed: %s" % exc)
        return
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    if not rows:
        print("  (no rows)")
        return
    widths = [
        max(len(str(c)), max((len(str(r[i])) for r in rows), default=0))
        for i, c in enumerate(cols)
    ]
    widths = [min(w, 42) for w in widths]
    print("  " + "  ".join(str(c)[: widths[i]].ljust(widths[i]) for i, c in enumerate(cols)))
    print("  " + "  ".join("-" * w for w in widths))
    for r in rows:
        print("  " + "  ".join(str(r[i])[: widths[i]].ljust(widths[i]) for i in range(len(cols))))


def main() -> int:
    url, where = load_url()
    if not url:
        print("No DATABASE_URL found.")
        return 1
    cfg = parse_url(url)
    print("Target: %s@%s:%s/%s  (from %s)"
          % (cfg["user"], cfg["host"], cfg["port"], cfg["database"], where))

    conn = connect(cfg)
    conn.autocommit = True
    cur = conn.cursor()

    table(cur, "auth_events (most recent 25)", """
        select to_char(occurred_at at time zone 'UTC', 'MM-DD HH24:MI:SS') as utc,
               kind::text,
               email,
               coalesce(host(ip), '-')          as ip,
               left(coalesce(user_id::text,'-'), 8) as user_id,
               coalesce(detail::text, '')       as detail
          from auth_events
         order by occurred_at desc
         limit 25
    """)

    table(cur, "app_users", """
        select left(id::text, 8) as id, email, coalesce(full_name,'-') as name,
               to_char(created_at at time zone 'UTC','MM-DD HH24:MI') as created
          from app_users order by created_at
    """)

    table(cur, "Auth.js users", """
        select left(id::text,8) as id, email,
               case when "emailVerified" is null then 'no' else 'yes' end as verified
          from users order by email
    """)

    # Count only. Never select "sessionToken".
    table(cur, "live sessions", """
        select count(*) as sessions,
               coalesce(to_char(min(expires) at time zone 'UTC','MM-DD HH24:MI'),'-') as first_expiry
          from sessions where expires > now()
    """)

    table(cur, "portal access (access_review)", """
        select franchise, email, is_active,
               coalesce(to_char(last_signin at time zone 'UTC','MM-DD HH24:MI'),'never') as last_signin,
               is_staff
          from access_review order by franchise, email
    """)

    table(cur, "orders", """
        select status::text, count(*) as n, coalesce(sum(estimated_total),0) as total
          from orders group by status order by status
    """)

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
