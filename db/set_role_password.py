#!/usr/bin/env python
"""
Set the password on the restricted `portal_app` role.

Reads PORTAL_APP_PASSWORD from the environment and runs ALTER ROLE. Run this
inside Railway, where the variable lives; the value never passes through a
terminal, a log line, or a chat transcript.

No-ops (exit 0) when the variable is unset, so it can sit safely in a start
command chain before anyone has set it.

The password is never printed. On success it reports only the SHA-256 prefix of
what it set, which is enough to confirm two places hold the same value without
disclosing it.
"""

import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apply import load_url, parse_url, connect, describe   # noqa: E402


def main() -> int:
    pw = os.environ.get("PORTAL_APP_PASSWORD", "")
    if not pw:
        print("PORTAL_APP_PASSWORD not set - skipping role password step.")
        return 0

    if len(pw) < 16:
        print("Refusing: PORTAL_APP_PASSWORD is shorter than 16 characters.")
        return 1

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

    cur.execute("select 1 from pg_roles where rolname = 'portal_app'")
    if not cur.fetchone():
        print("Role portal_app does not exist. Run db/verify_rls.py first.")
        return 1

    # Parameterising a role password is not possible - ALTER ROLE takes a
    # literal - so quote it as a literal server-side rather than by hand.
    cur.execute("select quote_literal(%s)", (pw,))
    literal = cur.fetchone()[0]
    cur.execute("alter role portal_app password " + literal)

    # Make sure the role can actually log in; created without a password it may
    # have been LOGIN already, but be explicit.
    cur.execute("alter role portal_app login")

    digest = hashlib.sha256(pw.encode("utf-8")).hexdigest()[:12]
    print("portal_app password set. sha256 prefix: %s" % digest)
    print("Set the app service's DATABASE_URL to use portal_app with this same value.")
    conn.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:                    # noqa: BLE001
        print("failed: %s" % describe(exc).get("message", str(exc)))
        sys.exit(1)
