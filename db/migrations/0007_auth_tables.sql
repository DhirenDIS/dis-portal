-- ============================================================================
-- Auth.js tables for magic-link sign-in
--
-- Table and column names here are NOT a matter of taste: @auth/pg-adapter
-- issues hardcoded SQL against them, including quoted camelCase identifiers.
-- These were read off the adapter's source (node_modules/@auth/pg-adapter/
-- src/index.ts) rather than written from memory, because a mismatch surfaces
-- as a runtime auth failure rather than a migration error.
--
-- Queries the adapter makes, for reference:
--   insert into verification_token (identifier, expires, token)
--   delete from verification_token where identifier = $1 and token = $2
--   insert into users (name, email, "emailVerified", image)
--   select * from users where id = $1 | email = $1
--   insert into accounts ("userId", provider, type, "providerAccountId",
--     access_token, expires_at, refresh_token, id_token, scope,
--     session_state, token_type)
--   insert into sessions ("userId", expires, "sessionToken")
--   delete from sessions where "sessionToken" = $1
--
-- app_users stays the canonical user table that every business FK points at.
-- A trigger mirrors Auth.js `users` into it, sharing the same id - the same
-- pattern 0000_identity.sql uses for Supabase's auth.users.
--
-- RLS: these tables are deliberately NOT row-level secured. They are touched
-- only by the server, before any user context exists (a verification token has
-- to be written for a person who is not yet signed in). They are never exposed
-- through a query the browser can reach. Access is controlled by grant alone.
-- ============================================================================

create table public.users (
  id              uuid primary key default gen_random_uuid(),
  name            text,
  email           text unique,
  "emailVerified" timestamptz,
  image           text
);

create table public.accounts (
  id                  uuid primary key default gen_random_uuid(),
  "userId"            uuid not null references public.users(id) on delete cascade,
  type                text not null,
  provider            text not null,
  "providerAccountId" text not null,
  refresh_token       text,
  access_token        text,
  expires_at          bigint,
  id_token            text,
  scope               text,
  session_state       text,
  token_type          text,
  unique (provider, "providerAccountId")
);
create index accounts_user_idx on public.accounts ("userId");

create table public.sessions (
  id             uuid primary key default gen_random_uuid(),
  "userId"       uuid not null references public.users(id) on delete cascade,
  expires        timestamptz not null,
  "sessionToken" text not null unique
);
create index sessions_user_idx on public.sessions ("userId");

create table public.verification_token (
  identifier text not null,
  expires    timestamptz not null,
  token      text not null,
  primary key (identifier, token)
);

-- ---------------------------------------------------------------------------
-- Mirror Auth.js users into app_users, sharing the id.
--
-- Note what this deliberately does NOT do: creating an Auth.js user grants no
-- access to anything. Access comes from a franchise_operators row, which only
-- staff can insert. So a stranger who requests a magic link for their own
-- address gets a valid session and sees nothing at all.
-- ---------------------------------------------------------------------------
create or replace function public.sync_auth_js_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.app_users (id, email, full_name)
  values (new.id, coalesce(new.email, new.id::text || '@no-email.invalid'), new.name)
  on conflict (id) do update
    set email     = excluded.email,
        full_name = coalesce(excluded.full_name, public.app_users.full_name);
  return new;
end;
$$;

create trigger sync_app_users_from_auth
  after insert or update of email, name on public.users
  for each row execute function public.sync_auth_js_user();

-- ---------------------------------------------------------------------------
-- Grants. The app connects as portal_app (a member of `authenticated`), which
-- needs direct DML here because there is no user context at sign-in time.
-- Nothing is granted to anon.
-- ---------------------------------------------------------------------------
grant select, insert, update, delete
  on public.users, public.accounts, public.sessions, public.verification_token
  to authenticated;

revoke all
  on public.users, public.accounts, public.sessions, public.verification_token
  from anon;

-- app_users is written by the trigger (security definer), so no direct grant.
