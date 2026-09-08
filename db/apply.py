#!/usr/bin/env python
"""
Apply the portal migrations to a Postgres database (Railway).

    python db/apply.py --check    apply everything in ONE transaction, then
                                  ROLL BACK. Nothing persists. Use this to
                                  shake out errors on a live database safely.

    python db/apply.py --apply    apply for real, one transaction per file,
                                  recording each in schema_migrations.

The connection string is read from the DATABASE_URL environment variable, or
from a .env file beside this script. It is never printed - only host/db/user
are echoed, never the password.
"""

import os
import re
import ssl
import sys
import io
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
MIGRATIONS = os.path.join(HERE, "migrations")


# --------------------------------------------------------------------------
# connection string
# --------------------------------------------------------------------------
def load_url():
    """Find the connection string. Tolerant of how people actually save files:
    a bare URL with no key, a BOM from Notepad, an `export ` prefix, quotes."""
    url = os.environ.get("DATABASE_URL", "").strip()
    if url:
        return url, "environment"

    candidates = []
    for name in (".env", ".env.local"):
        candidates.append(os.path.join(HERE, name))
        candidates.append(os.path.join(os.path.dirname(HERE), name))

    for path in candidates:
        if not os.path.exists(path):
            continue
        # utf-8-sig strips the BOM Notepad writes by default
        for line in io.open(path, encoding="utf-8-sig"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.lower().startswith("export "):
                line = line[7:].strip()
            key, sep, val = line.partition("=")
            if sep and key.strip().upper() == "DATABASE_URL":
                val = val.strip().strip('"').strip("'")
                if val:
                    return val, path
            # a bare URL on its own line, no key
            if not sep and line.lower().startswith(("postgres://", "postgresql://")):
                return line.strip('"').strip("'"), path + " (bare URL)"
    return None, None


def parse_url(url):
    u = urllib.parse.urlparse(url)
    if u.scheme not in ("postgres", "postgresql"):
        raise SystemExit("DATABASE_URL must start with postgres:// or postgresql://")
    return {
        "user": urllib.parse.unquote(u.username or "postgres"),
        "password": urllib.parse.unquote(u.password or ""),
        "host": u.hostname or "localhost",
        "port": u.port or 5432,
        "database": (u.path or "/postgres").lstrip("/") or "postgres",
    }


# --------------------------------------------------------------------------
# SQL splitting
#
# pg8000 speaks the extended query protocol, which takes one statement at a
# time, so the files have to be split. A naive split on ";" would cut every
# plpgsql function in half, so this tracks dollar-quoted bodies ($$ ... $$,
# $body$ ... $body$), ordinary quotes, and both comment styles.
# --------------------------------------------------------------------------
DOLLAR = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$")


def split_sql(text):
    out = []
    buf = []
    i = 0
    n = len(text)
    stmt_start = 0
    state = None          # None | 'line' | 'block' | 'squote' | 'dquote' | 'dollar'
    tag = None

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if state is None:
            if ch == "-" and nxt == "-":
                state = "line"
            elif ch == "/" and nxt == "*":
                state = "block"
            elif ch == "'":
                state = "squote"
            elif ch == '"':
                state = "dquote"
            elif ch == "$":
                m = DOLLAR.match(text, i)
                if m:
                    tag = m.group(0)
                    state = "dollar"
                    buf.append(tag)
                    i += len(tag)
                    continue
            elif ch == ";":
                buf.append(ch)
                s = "".join(buf).strip()
                if s.strip(";").strip():
                    out.append((text.count("\n", 0, stmt_start) + 1, s))
                buf = []
                i += 1
                stmt_start = i
                continue

        elif state == "line":
            if ch == "\n":
                state = None
        elif state == "block":
            if ch == "*" and nxt == "/":
                buf.append(ch)
                i += 1
                ch = "/"
                state = None
        elif state == "squote":
            if ch == "'":
                if nxt == "'":
                    buf.append(ch)
                    i += 1
                    ch = "'"
                else:
                    state = None
        elif state == "dquote":
            if ch == '"':
                state = None
        elif state == "dollar":
            if ch == "$":
                if text.startswith(tag, i):
                    buf.append(tag)
                    i += len(tag)
                    state = None
                    tag = None
                    continue

        buf.append(ch)
        i += 1

    s = "".join(buf).strip()
    if s.strip(";").strip():
        out.append((text.count("\n", 0, stmt_start) + 1, s))
    return out


# --------------------------------------------------------------------------
def connect(cfg):
    import pg8000.dbapi

    attempts = [
        ("verified TLS", ssl.create_default_context()),
    ]
    relaxed = ssl.create_default_context()
    relaxed.check_hostname = False
    relaxed.verify_mode = ssl.CERT_NONE
    attempts.append(("unverified TLS", relaxed))
    attempts.append(("no TLS", None))

    last = None
    for label, ctx in attempts:
        try:
            kw = dict(cfg)
            if ctx is not None:
                kw["ssl_context"] = ctx
            conn = pg8000.dbapi.connect(**kw)
            print("  connected (%s)" % label)
            return conn
        except Exception as exc:            # noqa: BLE001
            last = exc
            continue
    raise SystemExit("could not connect: %s: %s" % (type(last).__name__, last))


def describe(exc):
    """pg8000 raises DatabaseError whose arg is a dict of the server fields."""
    detail = {}
    if exc.args and isinstance(exc.args[0], dict):
        raw = exc.args[0]
        keymap = {
            "M": "message", "S": "severity", "C": "sqlstate", "D": "detail",
            "H": "hint", "P": "position", "W": "where", "n": "constraint",
            "t": "table", "c": "column", "d": "datatype", "F": "file",
            "L": "line", "R": "routine",
        }
        for k, v in raw.items():
            detail[keymap.get(k, k)] = v
    else:
        detail["message"] = str(exc)
    return detail


def show_error(fname, line, stmt, exc):
    d = describe(exc)
    print("\n" + "!" * 74)
    print("FAILED  %s  (statement starting line %d)" % (fname, line))
    print("!" * 74)
    for key in ("sqlstate", "severity", "message", "detail", "hint", "constraint",
                "table", "column", "where", "position", "routine"):
        if d.get(key):
            print("  %-10s %s" % (key + ":", d[key]))
    pos = d.get("position")
    head = stmt if len(stmt) < 1400 else stmt[:1400] + "\n  ... (truncated)"
    print("\n  --- statement ---")
    for ln in head.splitlines():
        print("  " + ln)
    if pos:
        try:
            p = int(pos)
            print("\n  --- around character %d ---" % p)
            print("  " + stmt[max(0, p - 90):p + 90].replace("\n", " "))
            print("  " + " " * min(90, p - 1) + "^")
        except (ValueError, TypeError):
            pass
    print()


def main():
    mode = "--check"
    for a in sys.argv[1:]:
        if a in ("--check", "--apply", "--ping"):
            mode = a
        else:
            raise SystemExit("unknown argument %r (use --ping, --check or --apply)" % a)

    url, where = load_url()
    if not url:
        raise SystemExit(
            "No DATABASE_URL found.\n"
            "Set it in your shell, or put it in Portal/db/.env as:\n"
            "  DATABASE_URL=postgresql://user:pass@host:port/dbname\n"
            "Get it from Railway: Postgres service -> Variables -> DATABASE_PUBLIC_URL"
        )

    cfg = parse_url(url)

    # Inside Railway the internal host is the right one to use. Outside it, it
    # cannot resolve at all, so catch that early with a useful message rather
    # than letting the connection hang.
    in_railway = any(os.environ.get(k) for k in
                     ("RAILWAY_ENVIRONMENT", "RAILWAY_ENVIRONMENT_NAME",
                      "RAILWAY_SERVICE_NAME", "RAILWAY_PROJECT_ID"))
    if in_railway:
        print("Running inside Railway (%s) - internal host is expected."
              % (os.environ.get("RAILWAY_ENVIRONMENT_NAME")
                 or os.environ.get("RAILWAY_ENVIRONMENT") or "unknown env"))

    if cfg["host"].endswith(".railway.internal") and not in_railway:
        raise SystemExit(
            ("That is Railway's INTERNAL host (%s), which only resolves inside"
             " Railway's own network - it can never connect from this machine."
             "\n\nUse DATABASE_PUBLIC_URL instead: Railway -> Postgres service"
             " -> Variables -> DATABASE_PUBLIC_URL. Its host looks like"
             " something.proxy.rlwy.net with a high port number."
             "\nIf it is not listed, enable Settings -> Networking -> TCP Proxy."
             ) % cfg["host"])
    print("Target: %s@%s:%s/%s   (from %s)"
          % (cfg["user"], cfg["host"], cfg["port"], cfg["database"], where))
    print("Mode:   %s" % {"--ping": "PING - connect and report capability only",
                          "--check": "DRY RUN - everything rolls back",
                          "--apply": "APPLY - changes are committed"}[mode])

    if mode == "--ping":
        conn = connect(cfg)
        conn.autocommit = True
        cur = conn.cursor()
        cur.execute("select version()")
        print("  server:   %s" % cur.fetchone()[0].split(",")[0])
        cur.execute("select current_user, current_database(),"
                    " current_setting('is_superuser')")
        who, dbname, su = cur.fetchone()
        print("  role:     %s (superuser=%s)" % (who, su))
        print("  database: %s" % dbname)
        cur.execute("select has_database_privilege(current_user, current_database(), 'CREATE')")
        print("  can CREATE in db:      %s" % cur.fetchone()[0])
        cur.execute("select has_schema_privilege(current_user, 'public', 'CREATE')")
        print("  can CREATE in public:  %s" % cur.fetchone()[0])
        cur.execute("select rolcreaterole from pg_roles where rolname = current_user")
        row = cur.fetchone()
        print("  can CREATE ROLE:       %s" % (row[0] if row else "unknown"))
        cur.execute("select count(*) from information_schema.schemata where schema_name = 'auth'")
        print("  has an 'auth' schema:  %s  (expected false on Railway)"
              % (cur.fetchone()[0] > 0))
        cur.execute("select count(*) from information_schema.tables"
                    " where table_schema = 'public'")
        n = cur.fetchone()[0]
        print("  tables in public:      %d %s" % (n, "(empty, good)" if n == 0 else
              "(NOT empty - migrations assume a clean database)"))
        conn.close()
        return

    files = sorted(f for f in os.listdir(MIGRATIONS) if f.endswith(".sql"))
    if not files:
        raise SystemExit("no .sql files in %s" % MIGRATIONS)
    print("Files:  %s\n" % ", ".join(files))

    conn = connect(cfg)
    conn.autocommit = False
    cur = conn.cursor()

    if mode == "--apply":
        cur.execute("""
            create table if not exists public.schema_migrations (
              filename    text primary key,
              applied_at  timestamptz not null default now()
            )""")
        conn.commit()

    ok_stmts = 0
    failed = False

    for fname in files:
        if mode == "--apply":
            cur.execute("select 1 from public.schema_migrations where filename = %s", (fname,))
            if cur.fetchone():
                print("  %-32s already applied, skipping" % fname)
                continue

        text = io.open(os.path.join(MIGRATIONS, fname), encoding="utf-8").read()
        stmts = split_sql(text)
        print("  %-32s %3d statements" % (fname, len(stmts)), end="")

        for line, stmt in stmts:
            try:
                cur.execute(stmt)
                ok_stmts += 1
            except Exception as exc:                    # noqa: BLE001
                print("   <- ERROR")
                show_error(fname, line, stmt, exc)
                failed = True
                break
        if failed:
            break
        print("   ok")

        if mode == "--apply":
            cur.execute("insert into public.schema_migrations (filename) values (%s)", (fname,))
            conn.commit()

    if failed:
        conn.rollback()
        print("Rolled back. %d statements had succeeded before the failure." % ok_stmts)
        conn.close()
        sys.exit(1)

    if mode == "--check":
        conn.rollback()
        print("\nAll %d statements executed cleanly. Rolled back - database unchanged." % ok_stmts)
    else:
        conn.commit()
        print("\nApplied %d statements. Committed." % ok_stmts)
    conn.close()


if __name__ == "__main__":
    main()
