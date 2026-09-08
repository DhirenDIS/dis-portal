#!/usr/bin/env python
"""
Grant a person access to a franchise, and optionally make them DIS staff.

    python db/grant_access.py <email> "<franchise name>" [--staff]
    python db/grant_access.py <email> --staff-only
    python db/grant_access.py <email> "<franchise name>" --revoke
    python db/grant_access.py <email> --revoke-staff

Run inside Railway, as the migration role.

This is the provisioning path an auditor will ask about (CC6.2/CC6.3), so it
behaves accordingly:

  - the person must already exist in app_users, i.e. they must have signed in
    at least once. We never create a user here, because inventing an account
    for an address nobody has proved they control is how you end up granting a
    franchise to a typo.
  - revoking sets is_active = false rather than deleting, so past orders stay
    attributable to a real person.
  - every insert and update passes through the audit triggers on
    franchise_operators and staff, so the grant is evidenced without anyone
    having to remember to write it down.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apply import load_url, parse_url, connect, describe   # noqa: E402


def scalar(cur, sql, params=()):
    cur.execute(sql, params)
    row = cur.fetchone()
    return row[0] if row else None


def main(argv) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}

    if not args:
        print(__doc__)
        return 2

    email = args[0].strip().lower()
    franchise = args[1].strip() if len(args) > 1 else None
    make_staff = "--staff" in flags or "--staff-only" in flags
    revoke = "--revoke" in flags

    url, where = load_url()
    if not url:
        print("No DATABASE_URL found.")
        return 1
    cfg = parse_url(url)
    print("Target: %s@%s:%s/%s  (from %s)"
          % (cfg["user"], cfg["host"], cfg["port"], cfg["database"], where))

    conn = connect(cfg)
    conn.autocommit = False
    cur = conn.cursor()

    user_id = scalar(cur, "select id from app_users where email = %s", (email,))
    if not user_id:
        print("\nNo app_users row for %s." % email)
        print("They must sign in once before access can be granted - that is")
        print("deliberate, so a mistyped address cannot be given a franchise.")
        conn.rollback()
        return 1
    print("\nUser: %s  (%s)" % (email, user_id))

    if "--revoke-staff" in flags:
        # Deactivate rather than delete, same reasoning as franchise access:
        # audit_log rows already point at this staff row as the actor.
        cur.execute("update staff set is_active = false where user_id = %s", (user_id,))
        print("  staff: deactivated (row kept - audit_log references it as an actor)")

    if make_staff:
        existing = scalar(cur, "select is_active from staff where user_id = %s", (user_id,))
        if existing is None:
            cur.execute(
                """insert into staff (user_id, full_name, email, is_active)
                   values (%s, %s, %s, true)""",
                (user_id, email.split("@")[0], email),
            )
            print("  staff: created")
        elif not existing:
            cur.execute("update staff set is_active = true where user_id = %s", (user_id,))
            print("  staff: reactivated")
        else:
            print("  staff: already active")

    if franchise:
        fid = scalar(cur, "select id from franchises where name = %s", (franchise,))
        if not fid:
            print("\nNo franchise named %r. Existing:" % franchise)
            cur.execute("select name from franchises order by name")
            for (n,) in cur.fetchall():
                print("    " + n)
            conn.rollback()
            return 1

        if revoke:
            cur.execute(
                """update franchise_operators set is_active = false
                    where franchise_id = %s and user_id = %s""",
                (fid, user_id),
            )
            print("  %s: access revoked (row kept for attribution)" % franchise)
        else:
            existing = scalar(
                cur,
                """select is_active from franchise_operators
                    where franchise_id = %s and user_id = %s""",
                (fid, user_id),
            )
            if existing is None:
                cur.execute(
                    """insert into franchise_operators
                       (franchise_id, user_id, email, is_active, accepted_at)
                       values (%s, %s, %s, true, now())""",
                    (fid, user_id, email),
                )
                print("  %s: access granted" % franchise)
            elif not existing:
                cur.execute(
                    """update franchise_operators set is_active = true
                        where franchise_id = %s and user_id = %s""",
                    (fid, user_id),
                )
                print("  %s: access restored" % franchise)
            else:
                print("  %s: already had access" % franchise)

    conn.commit()

    print("\n=== access now ===")
    cur.execute(
        """select franchise, email, is_active, is_staff
             from access_review where email = %s order by franchise""",
        (email,),
    )
    rows = cur.fetchall()
    if not rows:
        print("  (no franchise access)")
    for r in rows:
        print("  %-22s %-24s active=%s staff=%s" % (r[0], r[1], r[2], r[3]))

    conn.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:                     # noqa: BLE001
        print("failed: %s" % describe(exc).get("message", str(exc)))
        sys.exit(1)
