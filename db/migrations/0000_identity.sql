-- ============================================================================
-- Identity layer - runs FIRST
--
-- Hosting is Railway, so this schema must not assume Supabase. Everything that
-- would normally be Supabase-specific is funnelled through two objects:
--
--   public.app_users        the canonical user table all FKs point at
--   public.current_user_id()  who is calling, however the app authenticates
--
-- That makes the same migrations work in both places:
--
--   Railway Postgres + Auth.js magic links
--     The app opens a connection per request and does:
--         set local role authenticated;
--         set local app.user_id = '<uuid of the signed-in user>';
--     RLS then behaves exactly as it would on Supabase.
--
--   Supabase Postgres (if you ever move the DB there)
--     auth.uid() resolves the JWT and the trigger at the bottom mirrors
--     auth.users into app_users. No policy changes needed.
--
-- IMPORTANT for Railway: the app's normal connection role must NOT be a
-- superuser or the table owner, because RLS is bypassed for both. Create a
-- dedicated login role, grant it `authenticated`, and connect as that.
-- ============================================================================

create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "citext";     -- case-insensitive email

-- ---------------------------------------------------------------------------
-- Roles. Supabase ships these; Railway does not.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Canonical users
-- ---------------------------------------------------------------------------
create table public.app_users (
  id           uuid primary key default gen_random_uuid(),
  email        citext not null unique,
  full_name    text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz
);
comment on table public.app_users is
  'Every user - DIS staff and franchise operators alike. On Supabase this mirrors auth.users; on Railway it is the source of truth and Auth.js writes to it.';

create index app_users_email_idx on public.app_users (email);

-- ---------------------------------------------------------------------------
-- Who is calling?
--
-- Tries the Supabase JWT first, then the session variable the Railway app
-- sets. Wrapped in EXECUTE so this function still compiles on a database with
-- no `auth` schema at all.
-- ---------------------------------------------------------------------------
create or replace function public.current_user_id()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- Supabase / PostgREST
  begin
    execute 'select auth.uid()' into v_id;
  exception when others then
    v_id := null;
  end;
  if v_id is not null then
    return v_id;
  end if;

  -- Railway: set local app.user_id = '...' per request
  begin
    v_id := nullif(current_setting('app.user_id', true), '')::uuid;
  exception when others then
    v_id := null;
  end;

  return v_id;
end;
$$;

comment on function public.current_user_id() is
  'Single point of truth for caller identity. Swap the body, not the policies, if auth changes again.';

-- ---------------------------------------------------------------------------
-- Supabase compatibility: keep app_users in step with auth.users.
-- Skipped silently on Railway, where there is no auth schema.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'auth') then
    execute $fn$
      create or replace function public.sync_auth_user()
      returns trigger
      language plpgsql
      security definer
      set search_path = ''
      as $body$
      begin
        insert into public.app_users (id, email, full_name)
        values (new.id, new.email,
                coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'))
        on conflict (id) do update
          set email = excluded.email,
              full_name = coalesce(excluded.full_name, public.app_users.full_name);
        return new;
      end;
      $body$;
    $fn$;

    execute 'drop trigger if exists sync_app_users on auth.users';
    execute 'create trigger sync_app_users after insert or update of email on auth.users
             for each row execute function public.sync_auth_user()';
  end if;
end
$$;

alter table public.app_users enable row level security;

grant usage on schema public to authenticated, anon;
grant select on public.app_users to authenticated;

-- A user may read their own row. Staff read all - the policy for that is added
-- in 0002 once is_staff() exists.
create policy app_users_self_read on public.app_users
  for select to authenticated
  using (id = public.current_user_id());
