# Deploying the franchise portal on Railway

Start-to-finish. Database first, app second, because the app needs the database
to exist and the migrations are the thing most likely to bite.

**Read this first:** the migrations run *inside* Railway, not from your desktop.
That means no TCP proxy, no database exposed to the internet, and no connection
string on your machine. It is both easier and safer than what we tried before.

Where things stand:

| | Status |
|---|---|
| Database schema — 6 migrations, ~1,250 lines SQL | written, **never executed** |
| Migration runner (`db/apply.py`) | written, splitter tested locally |
| Prototype portal (`weedman-portal.html`) | working, no auth, single-operator |
| Next.js app — auth, order flow, staff console | **not built yet** |

So Phases 1–4 are doable today. Phase 5 is where the app gets built.

---

## Phase 0 — clean slate

If you already made a project while we were poking around, delete it. It has a
database with a leaked password and a half-configured proxy.

Railway dashboard → the project → **Settings** → **Danger** → **Delete Project**.

---

## Phase 1 — put the code in a repo

Railway deploys from a Git repo. Right now `Portal/` is just a folder.

```bash
cd /c/Users/dhire/Portal
git init -b main
git add .
git commit -m "Portal: database schema, migration runner, prototype"
```

`.gitignore` already excludes `.env`, so no secrets go in. Verify before you push:

```bash
git status --short          # .env must NOT appear
```

Then create a **private** repo on GitHub called `dis-portal` and push:

```bash
git remote add origin https://github.com/<you>/dis-portal.git
git push -u origin main
```

> Private, not public. Once this holds franchisee names and addresses it is PII
> under your SOC 2 scope, and the schema alone tells anyone how your access
> control works.

---

## Phase 2 — the database

1. Railway → **New Project** → name it `dis-portal-dev`
2. **+ New** → **Database** → **PostgreSQL**

That is it. Do **not** add a TCP proxy. Do **not** copy any connection string.

Railway gives the Postgres service a `DATABASE_URL` on the internal network,
and any other service in the same project can reference it.

---

## Phase 3 — run the migrations inside Railway

This is the step that finds the SQL errors.

1. In the same project: **+ New** → **GitHub Repo** → pick `dis-portal`
2. Railway detects Python from `requirements.txt` and reads `railway.json`,
   which sets the start command to `python db/apply.py --check`
3. Name the service `migrate`
4. Open the `migrate` service → **Variables** → **+ New Variable** →
   **Add Reference** → pick the Postgres service's `DATABASE_URL`

   Referencing it, rather than pasting the value, means a password rotation
   never silently breaks this.
5. **Deploy**, then open the **Deploy Logs**

`--check` runs all 156 statements in one transaction and then rolls back.
Nothing persists. Read the log:

- **`All 156 statements executed cleanly. Rolled back`** — the schema is sound,
  go to step 6.
- **A `FAILED` block** — it names the file, the line the statement starts on,
  the SQLSTATE, the server message and hint, and prints the statement with a
  caret at the failing character. Paste that block to me, I fix it, you
  redeploy. Expect two or three rounds; this is what the phase is for.

6. When it is clean, change the start command to commit for real:
   service → **Settings** → **Deploy** → **Custom Start Command**:

   ```
   python db/apply.py --apply
   ```

   Redeploy. Each file now commits in its own transaction and is recorded in
   `schema_migrations`, so re-running is a no-op rather than an error.

7. Confirm, then **delete the `migrate` service**. Its job is done, and leaving
   a service around whose start command mutates your schema is a foot-gun.

> Later, once the app exists, migrations move to the app service's
> **Pre-Deploy Command** so they run automatically ahead of each release.

---

## Phase 4 — the restricted database role

**Do not skip this.** Postgres bypasses RLS for superusers and for a table's
owner. Railway's default `postgres` user is both. If the app connects as
`postgres`, every policy in `0002_rls.sql` is silently inert and every operator
can read every franchise's orders. The schema will look correct and enforce
nothing.

Open the Postgres service → **Data** tab → query runner, and run:

```sql
create role portal_app login password 'GENERATE-SOMETHING-LONG' inherit;
grant authenticated to portal_app;
grant usage on schema public to portal_app;
```

Then prove it works:

```sql
set role portal_app;
select count(*) from orders;        -- expect 0 rows, not an error
reset role;
```

Zero rows while `app.user_id` is unset is RLS doing its job. If you get all the
rows back, the role is over-privileged and something above did not take.

Build that role's connection string by taking the Postgres service's
`DATABASE_URL` and swapping the user and password for `portal_app`. Store it on
the **app** service as `DATABASE_URL` — this is the one variable you set by
hand rather than by reference.

---

## Phase 5 — the app

The Next.js app does not exist yet. When it does, it needs:

**Service setup**
- **+ New** → **GitHub Repo** → same repo, root directory `app/`
- Build: `npm run build` · Start: `npm start`
- **Pre-Deploy Command**: `python db/apply.py --apply`

**Variables**
| Variable | Value |
|---|---|
| `DATABASE_URL` | the `portal_app` string from Phase 4 |
| `AUTH_SECRET` | `openssl rand -base64 32` |
| `AUTH_URL` | your public URL, e.g. `https://portal.disdirect.com` |
| `EMAIL_FROM` | e.g. `mail@disdirect.com` |
| `RESEND_API_KEY` | for sending the magic links |

**Magic links need a real sender.** Auth.js emails the link; something has to
deliver it. Resend or SES, on a domain you control, with SPF/DKIM set up —
otherwise the links land in franchisees' spam and you will spend launch week on
the phone. This is worth sorting before you invite 100 people.

**Domain**: app service → **Settings** → **Networking** → **Custom Domain**,
add the CNAME Railway gives you. Set `AUTH_URL` to match exactly, or the
magic-link callback breaks.

**Per-request identity.** The app must set the caller on every request, in a
transaction — see `db/README.md`:

```sql
begin;
set local role authenticated;
set local app.user_id = '<uuid from the session>';
```

---

## Phase 6 — before you let anyone in

- [ ] Prove RLS: sign in as an operator, confirm exactly one franchise and zero
      other franchises' orders
- [ ] Try to cheat: as an operator, `update orders set status='submitted',
      estimated_total=1`. Must be rejected.
- [ ] Try a ZIP outside your territory on an order. Must be rejected.
- [ ] Try `update audit_log`. Must be rejected.
- [ ] Replace the placeholder `formats.unit_price` values with real DIS pricing
- [ ] Replace `zip_profiles` estimates with a real list pull
- [ ] Turn on Postgres backups (Railway service → Settings)
- [ ] Separate `dis-portal-prod` from `dis-portal-dev` — never one database

---

## Cost

Railway bills per usage. A Postgres service plus one small always-on web
service is roughly $10–20/month at this scale. 100 operators placing a handful
of orders per wave is a trivial load; the database will idle.

---

## Order of operations, condensed

```
0. delete the old project
1. git init, push to a private GitHub repo
2. new project + PostgreSQL          (no proxy, no copied secrets)
3. migrate service, --check, fix errors, --apply, delete service
4. create portal_app role, prove RLS blocks it
5. build the app, deploy it, set variables, custom domain
6. work the checklist above before inviting anyone
```
