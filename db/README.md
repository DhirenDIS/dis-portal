# Franchise mailing portal — database

Postgres schema for the DIS Direct portal where Weed Man franchise operators
build and submit mail/hanger orders. Sized for ~100 operators.

Decisions this is built on:

- **Billing:** invoice to account. No card data is stored or processed, so this
  database is out of PCI scope entirely.
- **Auth:** email magic link. Operators never set a password.
- **Hosting:** Railway. The schema does not depend on Supabase — see
  [Identity](#identity) — but still runs unchanged on it.

---

## Apply order

```
0000_identity.sql            roles, app_users, current_user_id()
0001_schema.sql              tables, enums, RLS switched on
0002_rls.sql                 every policy + the write guards
0003_estimate_and_submit.sql audience estimate + submit_order()
0004_audit.sql               append-only audit trail
0005_seed_reference.sql      brand, formats, criteria, ZIP profiles, one wave
```

Strictly in that order — `0000` creates the objects the rest reference.

```bash
for f in db/migrations/*.sql; do psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"; done
```

---

## Access model

Two audiences, one predicate each:

| | Sees | Writes |
|---|---|---|
| **Operator** (`franchise_operators`) | only franchises they are an *active* member of | own orders, and only while `status = 'draft'` |
| **Staff** (`staff`) | everything | everything |
| **anon** | nothing | nothing |

Reference data — ZIP profiles, criteria bands, formats, waves — is readable by
any signed-in user and writable only by staff.

Every table has RLS enabled. A table with RLS on and no policy denies all
access, so a future migration that forgets a policy fails closed.

### The rules that aren't expressible as RLS

- `submit_order()` is **the only** way an operator's order leaves `draft`.
  Their own `UPDATE` is constrained by policy to leave `status = 'draft'`, and
  `guard_order_transition` rejects any client attempt to write
  `unit_price_snapshot`, `estimated_total`, or the submitted/approved fields.
  The function sets a transaction-local marker (`app.submitting_order`) that
  the guard recognises; nothing reachable over the API can set it.
- **Price is snapshotted at submit.** Changing `formats.unit_price` later never
  rewrites a historical order.
- A ZIP added to an order must be inside that franchise's territory
  (`franchise_zips`), enforced by trigger.
- The **estimate lives in SQL**, not the browser, so the number the operator
  sees, the number on the order, and the number DIS quotes are one number.

---

## Identity

Everything auth-specific is funnelled through two objects so the rest of the
schema is host-agnostic:

- `public.app_users` — canonical user table; every FK points here
- `public.current_user_id()` — resolves the caller

`current_user_id()` tries `auth.uid()` (Supabase/PostgREST) and falls back to
`current_setting('app.user_id')`. If auth ever changes again, you change that
one function body — not 32 policies.

### Railway wiring

Your app must set the caller per request, inside a transaction:

```sql
begin;
set local role authenticated;
set local app.user_id = '<uuid from the Auth.js session>';
-- ... queries ...
commit;
```

`set local` dies with the transaction, so identity can never leak between
pooled requests.

> **The one thing that will silently break security:** RLS is bypassed for
> superusers and for a table's owner. If your app connects as the role that ran
> these migrations, every policy here is inert. Create a separate login role,
> grant it `authenticated`, and point `DATABASE_URL` at that:
>
> ```sql
> create role portal_app login password '...' inherit;
> grant authenticated to portal_app;
> ```
>
> Verify with `set role portal_app;` then `select * from orders;` — you should
> see nothing until `app.user_id` is set.

---

## Audit trail

`audit_log` is written by triggers, not app code, on the tables that carry
money, access, or a commitment to print: `orders`, `order_zips`,
`order_criteria`, `franchise_operators`, `franchise_zips`, `formats`, `staff`.

It is append-only. There is no `UPDATE`/`DELETE` policy and those privileges
are revoked outright, so nothing reachable through the API can rewrite history.
Operators can read their own franchise's entries; staff read all.

---

## What is real, and what is a placeholder

**Real** — taken from the production PDFs (28633-1, 28604-1, 28607-1):
format names, trim sizes with bleed, delivery method, promo codes DM29/DH29,
the Aurora phone and web address, and the `$29.95 first service` offer.

**Placeholder — replace before launch:**

| Item | Why it's a guess |
|---|---|
| `formats.unit_price` — $0.46 postcard, $0.38 hanger | I don't have real DIS pricing. Hangers are lower because hand-delivery carries no postage. |
| `zip_profiles.*` — 10 DuPage-area ZIPs | Modelled estimates. Every row is `source = 'estimate'`. Replace with real counts on first list pull. |
| `criteria_types` rows 3–5 | `home_value`, `length_of_residence`, `property_type` ship `is_active = false` with no `profile_col`. These are the portal's reserved criteria slots. |

To activate a reserved criterion: set its `profile_col` to a `zip_profiles`
column, give it a `spread`, insert its `criteria_bands`, flip `is_active`. No
application code changes — `criteria_share()` reads it from the table.

---

## Not yet verified

**This SQL has not been executed.** There is no Postgres, Docker, or Supabase
CLI on the machine it was written on, so it is reviewed, not tested. Balanced
dollar-quoting and object references were checked statically; a real
`psql -f` run against a scratch database is the next step and will likely turn
up a typo or two.

Worth testing first, in this order:

1. All six files apply clean on an empty database.
2. `set role authenticated` + `set local app.user_id` to an operator, then
   confirm they see exactly one franchise and zero other orders.
3. `submit_order()` on a draft — confirm it prices, snapshots, and flips to
   `submitted`.
4. Try to cheat: `update orders set status='submitted', estimated_total=1` as
   an operator. Both must be rejected.
5. Try `insert into order_zips` with a ZIP outside territory. Must be rejected.
6. `update audit_log` as an operator. Must be rejected.

---

## Still to build

- Next.js app on Railway: Auth.js magic-link provider + an email sender
- Operator invite flow for the ~100 operators (staff-only `franchise_operators` insert)
- Staff console: approve orders, move through production, manage territory and pricing
- Artwork upload to object storage; `format_artwork.storage_path` is the pointer
- Invoice generation on approval
