#!/usr/bin/env python
"""
Create the restricted `portal_app` role and prove the access control works.

Run this INSIDE Railway (it uses the internal DATABASE_URL), as the migration
role. It does two things:

  1. Creates `portal_app` and grants it `authenticated`. Committed.
  2. Builds throwaway fixtures (two franchises, two operators, an order each),
     switches to `portal_app`, and asserts what an operator can and cannot do.
     All of that is rolled back, so the database is left with only the role.

The point is the negative tests. A schema that merely *applies* proves nothing;
what matters is that an operator is blocked from the four things they must
never be able to do. Any FAIL below means the access control is decorative.

NOTE ON `INHERIT`: policies are written `TO authenticated`. Postgres applies a
policy when the current role has the privileges of a role in that list, which
requires INHERIT. A NOINHERIT role would be denied everything instead of being
scoped - a confusing failure that looks like working security. So portal_app is
created INHERIT.

No password is set here. `SET ROLE` needs none, and a password belongs in
Railway's variables, not in this script or its logs.
"""

import io
import os
import sys
import uuid
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apply import load_url, parse_url, connect, describe   # noqa: E402

results = []


def record(name, passed, detail=""):
    results.append((passed, name, detail))
    print("  %-58s %s%s" % (name, "PASS" if passed else "FAIL",
                            ("  <- " + detail) if detail else ""))


def expect_ok(cur, name, sql, args=None):
    cur.execute("savepoint sp")
    try:
        cur.execute(sql, args or ())
        cur.execute("release savepoint sp")
        record(name, True)
        return True
    except Exception as exc:                      # noqa: BLE001
        cur.execute("rollback to savepoint sp")
        record(name, False, describe(exc).get("message", str(exc))[:110])
        return False


def expect_blocked(cur, name, sql, args=None):
    """The whole point: this statement MUST be rejected."""
    cur.execute("savepoint sp")
    try:
        cur.execute(sql, args or ())
        cur.execute("rollback to savepoint sp")
        record(name, False, "STATEMENT SUCCEEDED - it should have been rejected")
        return False
    except Exception as exc:                      # noqa: BLE001
        cur.execute("rollback to savepoint sp")
        d = describe(exc)
        record(name, True, "%s %s" % (d.get("sqlstate", ""),
                                      (d.get("message") or "")[:80]))
        return True


def scalar(cur, sql, args=None):
    cur.execute(sql, args or ())
    row = cur.fetchone()
    return row[0] if row else None


def main():
    url, where = load_url()
    if not url:
        raise SystemExit("No DATABASE_URL found")
    cfg = parse_url(url)
    print("Target: %s@%s:%s/%s  (from %s)"
          % (cfg["user"], cfg["host"], cfg["port"], cfg["database"], where))

    conn = connect(cfg)
    conn.autocommit = True
    cur = conn.cursor()

    # ---------------------------------------------------------------- role
    print("\n=== 1. restricted role ===")
    exists = scalar(cur, "select 1 from pg_roles where rolname = 'portal_app'")
    if exists:
        print("  portal_app already exists - leaving it alone")
    else:
        cur.execute("create role portal_app login inherit")
        print("  created role portal_app (login, inherit, no password yet)")
    cur.execute("grant authenticated to portal_app")
    cur.execute("grant usage on schema public to portal_app")
    print("  granted authenticated + usage on public")
    print("  NOTE: set a password before the app uses it:")
    print("        alter role portal_app password '<from Railway variables>';")

    # ------------------------------------------------------------ fixtures
    print("\n=== 2. fixtures (rolled back at the end) ===")
    conn.autocommit = False

    op_a, op_b = str(uuid.uuid4()), str(uuid.uuid4())
    cur.execute("insert into app_users (id, email, full_name) values (%s,%s,%s)",
                (op_a, "operator-a@example.test", "Operator A"))
    cur.execute("insert into app_users (id, email, full_name) values (%s,%s,%s)",
                (op_b, "operator-b@example.test", "Operator B"))

    brand = scalar(cur, "select id from brands where slug = 'weed-man'")
    fr_a = scalar(cur, "select id from franchises where name = 'Weed Man Aurora'")
    fr_b = str(uuid.uuid4())
    cur.execute("""insert into franchises (id, brand_id, name, city, state, home_zip)
                   values (%s,%s,'Weed Man Naperville','Naperville','IL','60540')""",
                (fr_b, brand))
    # give B a territory that does NOT include 60564
    cur.execute("insert into franchise_zips (franchise_id, zip) values (%s,'60563')", (fr_b,))

    cur.execute("""insert into franchise_operators (franchise_id, user_id, email, is_active)
                   values (%s,%s,'operator-a@example.test',true)""", (fr_a, op_a))
    cur.execute("""insert into franchise_operators (franchise_id, user_id, email, is_active)
                   values (%s,%s,'operator-b@example.test',true)""", (fr_b, op_b))

    wave = scalar(cur, "select id from waves where is_open order by order_cutoff limit 1")
    fmt = scalar(cur, "select id from formats where code = 'pc-11x55'")
    unit_price = scalar(cur, "select unit_price from formats where id = %s", (fmt,))

    ord_a, ord_b = str(uuid.uuid4()), str(uuid.uuid4())
    for oid, fid, uid in ((ord_a, fr_a, op_a), (ord_b, fr_b, op_b)):
        cur.execute("""insert into orders
                       (id, franchise_id, wave_id, format_id, status, billing_method, created_by)
                       values (%s,%s,%s,%s,'draft','invoice_franchise',%s)""",
                    (oid, fid, wave, fmt, uid))
    # order A targets a ZIP inside Aurora's territory
    cur.execute("insert into order_zips (order_id, zip, estimated_addresses) values (%s,'60540',0)",
                (ord_a,))
    cur.execute("""insert into order_criteria (order_id, criteria_code, band_code)
                   values (%s,'household_income','i4')""", (ord_a,))
    print("  2 franchises, 2 operators, 2 draft orders created")

    # ------------------------------------------------- act as the operator
    print("\n=== 3. as portal_app, no identity set ===")
    cur.execute("set local role portal_app")
    record("current_user is portal_app", scalar(cur, "select current_user") == "portal_app",
           scalar(cur, "select current_user"))
    n = scalar(cur, "select count(*) from orders")
    record("anonymous session sees 0 orders", n == 0, "saw %s" % n)
    n = scalar(cur, "select count(*) from franchises")
    record("anonymous session sees 0 franchises", n == 0, "saw %s" % n)

    print("\n=== 4. as Operator A ===")
    cur.execute("select set_config('app.user_id', %s, true)", (op_a,))
    who = scalar(cur, "select public.current_user_id()")
    record("current_user_id() resolves the session variable", str(who) == op_a, str(who))

    n = scalar(cur, "select count(*) from franchises")
    record("sees exactly 1 franchise (own)", n == 1, "saw %s" % n)
    name = scalar(cur, "select name from franchises")
    record("and it is Aurora", name == "Weed Man Aurora", str(name))

    n = scalar(cur, "select count(*) from orders")
    record("sees exactly 1 order (own)", n == 1, "saw %s" % n)
    n = scalar(cur, "select count(*) from orders where id = %s", (ord_b,))
    record("cannot see the other franchise's order", n == 0, "saw %s" % n)
    n = scalar(cur, "select count(*) from franchise_zips")
    record("sees only own territory rows", n == 10, "saw %s" % n)
    record("is not staff", scalar(cur, "select public.is_staff()") is False)

    print("\n=== 5. the four things an operator must NOT be able to do ===")
    expect_blocked(cur, "cannot self-submit with own pricing",
                   "update orders set status='submitted', estimated_total=1 where id=%s", (ord_a,))
    expect_blocked(cur, "cannot add a ZIP outside territory",
                   "insert into order_zips (order_id, zip) values (%s,'99999')", (ord_a,))
    expect_blocked(cur, "cannot rewrite the audit trail",
                   "update audit_log set actor_email='forged'")
    expect_blocked(cur, "cannot grant themselves another franchise",
                   """insert into franchise_operators (franchise_id, user_id, email)
                      values (%s,%s,'operator-a@example.test')""", (fr_b, op_a))

    print("\n=== 6. extra escalation attempts ===")
    expect_blocked(cur, "cannot delete the audit trail", "delete from audit_log")
    expect_blocked(cur, "cannot make themselves staff",
                   "insert into staff (user_id, full_name, email) values (%s,'x','x@y.test')", (op_a,))
    expect_blocked(cur, "cannot change the piece price",
                   "update formats set unit_price = 0.01")
    expect_blocked(cur, "cannot move their order to another franchise",
                   "update orders set franchise_id=%s where id=%s", (fr_b, ord_a))

    print("\n=== 7. the happy path still works ===")
    expect_ok(cur, "can edit own draft", "update orders set notes='hello' where id=%s", (ord_a,))
    if expect_ok(cur, "submit_order() succeeds", "select public.submit_order(%s)", (ord_a,)):
        st = scalar(cur, "select status from orders where id=%s", (ord_a,))
        record("order is now submitted", str(st) == "submitted", str(st))
        snap = scalar(cur, "select unit_price_snapshot from orders where id=%s", (ord_a,))
        record("price was snapshotted server-side", snap == unit_price,
               "snapshot=%s formats=%s" % (snap, unit_price))
        addr = scalar(cur, "select estimated_addresses from orders where id=%s", (ord_a,))
        record("addresses estimated > 0", (addr or 0) > 0, "got %s" % addr)
        tot = scalar(cur, "select estimated_total from orders where id=%s", (ord_a,))
        record("total = addresses x unit price",
               tot is not None and abs(float(tot) - float(addr) * float(unit_price)) < 0.01,
               "total=%s" % tot)
        # A submitted order is protected by the USING clause of
        # orders_update_draft, which no longer matches once status <> 'draft'.
        # RLS filtering an UPDATE does NOT raise - it silently affects zero
        # rows. So assert on rowcount and on the data being unchanged, not on
        # an exception. (The app must check rowcount and tell the operator the
        # order is locked, or the edit appears to succeed in the UI.)
        before = scalar(cur, "select notes from orders where id=%s", (ord_a,))
        cur.execute("update orders set notes='TAMPERED' where id=%s", (ord_a,))
        affected = cur.rowcount
        after = scalar(cur, "select notes from orders where id=%s", (ord_a,))
        record("submitted order: update affects 0 rows", affected == 0,
               "rowcount=%s" % affected)
        record("submitted order: notes unchanged", after == before,
               "before=%r after=%r" % (before, after))
        n = scalar(cur, "select count(*) from audit_log where record_id = %s", (str(ord_a),))
        record("the submission was audited", (n or 0) > 0, "%s rows" % n)

    # ------------------------------------------------------------- cleanup
    cur.execute("reset role")
    conn.rollback()
    print("\nFixtures rolled back. Only the portal_app role persists.")

    failed = [r for r in results if not r[0]]
    print("\n%d checks, %d passed, %d FAILED" % (len(results), len(results) - len(failed), len(failed)))
    if failed:
        print("\nFAILURES:")
        for _, name, detail in failed:
            print("  - %s  %s" % (name, detail))
    conn.close()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
