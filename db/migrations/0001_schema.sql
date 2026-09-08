-- ============================================================================
-- DIS Direct franchise mailing portal - core schema
-- Target: Postgres 15+ on Railway (also runs unchanged on Supabase).
-- Apply in filename order, starting at 0000_identity.sql.
--
-- Access model in one line: a franchise operator signs in with a magic link and
-- can only ever see rows belonging to a franchise they are an active member of.
-- DIS staff see everything. Orders are billed to account - no card data is ever
-- stored or processed here, which keeps this database out of PCI scope.
--
-- Every table gets RLS enabled here and its policies in 0002_rls.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.delivery_method as enum ('usps_mail', 'hand_delivered');

create type public.order_status as enum (
  'draft',        -- operator is still building it; only state they may edit
  'submitted',    -- operator signed off; locked to the operator
  'approved',     -- DIS accepted it into a production wave
  'in_production',
  'delivered',
  'cancelled'
);

create type public.billing_method as enum ('invoice_franchise', 'invoice_corporate');

-- ---------------------------------------------------------------------------
-- Helper predicates used by RLS.
--
-- security definer so an operator can test membership without being able to
-- read the membership table wholesale; search_path pinned to '' so a mutable
-- search_path cannot be used to shadow these objects.
-- ---------------------------------------------------------------------------
create table public.staff (
  user_id     uuid primary key references public.app_users(id) on delete cascade,
  full_name   text not null,
  email       citext not null unique,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
comment on table public.staff is 'DIS Direct employees. Membership here grants read/write across all franchises.';

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff s
    where s.user_id = public.current_user_id() and s.is_active
  );
$$;

-- ---------------------------------------------------------------------------
-- Organisations
-- ---------------------------------------------------------------------------
create table public.brands (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,              -- 'Weed Man'
  slug        text not null unique,
  created_at  timestamptz not null default now()
);

create table public.franchises (
  id            uuid primary key default gen_random_uuid(),
  brand_id      uuid not null references public.brands(id) on delete restrict,
  name          text not null,                   -- 'Weed Man Aurora'
  city          text not null,
  state         char(2) not null,
  phone         text,                            -- printed on the artwork
  web           text,
  home_zip      char(5),
  billing_method public.billing_method not null default 'invoice_franchise',
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (brand_id, name)
);

-- Which operator may act for which franchise. An operator can hold several.
create table public.franchise_operators (
  franchise_id uuid not null references public.franchises(id) on delete cascade,
  user_id      uuid not null references public.app_users(id) on delete cascade,
  email        citext not null,
  full_name    text,
  is_active    boolean not null default true,
  invited_at   timestamptz not null default now(),
  accepted_at  timestamptz,
  primary key (franchise_id, user_id)
);
comment on table public.franchise_operators is
  'Membership drives every operator-facing RLS policy. Deactivate rather than delete to keep order history attributable.';

-- RLS predicate columns must be indexed or every policy check is a seq scan.
create index franchise_operators_user_idx on public.franchise_operators (user_id) where is_active;
create index franchise_operators_franchise_idx on public.franchise_operators (franchise_id);

create or replace function public.is_operator_of(p_franchise uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.franchise_operators fo
    where fo.franchise_id = p_franchise
      and fo.user_id = public.current_user_id()
      and fo.is_active
  );
$$;

-- The franchise ids the caller may act for. Used by IN (...) policies.
create or replace function public.my_franchise_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select fo.franchise_id from public.franchise_operators fo
  where fo.user_id = public.current_user_id() and fo.is_active;
$$;

-- Territory: the ZIPs in the franchise agreement.
create table public.franchise_zips (
  franchise_id uuid not null references public.franchises(id) on delete cascade,
  zip          char(5) not null,
  added_at     timestamptz not null default now(),
  primary key (franchise_id, zip)
);

-- ---------------------------------------------------------------------------
-- Reference data: household universe and targeting criteria
-- ---------------------------------------------------------------------------
create table public.zip_profiles (
  zip                char(5) primary key,
  city               text not null,
  state              char(2) not null,
  households         integer not null check (households >= 0),
  owner_occ_share    numeric(4,3) not null check (owner_occ_share between 0 and 1),
  median_income      integer not null check (median_income > 0),
  median_lot_sqft    integer not null check (median_lot_sqft > 0),
  source             text not null default 'estimate',   -- 'estimate' | 'list_pull' | 'census'
  updated_at         timestamptz not null default now()
);
comment on table public.zip_profiles is
  'Household universe per ZIP. source=estimate means the counts are modelled, not from a real list pull.';

-- Criteria bands. Held as data so new criteria need no code change - this is
-- where the portal placeholders get filled in.
create table public.criteria_types (
  code        text primary key,              -- 'household_income', 'lot_size'
  label       text not null,
  unit        text,                          -- 'usd', 'sqft'
  profile_col text,                          -- zip_profiles column the bands score against
  spread      numeric(4,3),                  -- log-logistic shape for the estimate
  sort_order  integer not null default 0,
  is_active   boolean not null default false -- placeholders ship inactive
);

create table public.criteria_bands (
  id            uuid primary key default gen_random_uuid(),
  criteria_code text not null references public.criteria_types(code) on delete cascade,
  code          text not null,               -- 'i4'
  label         text not null,               -- '$100k-$150k'
  lower_bound   numeric,                     -- inclusive; null = unbounded below
  upper_bound   numeric,                     -- exclusive; null = unbounded above
  sort_order    integer not null default 0,
  unique (criteria_code, code),
  check (lower_bound is null or upper_bound is null or lower_bound < upper_bound)
);

-- ---------------------------------------------------------------------------
-- Print formats
-- ---------------------------------------------------------------------------
create table public.formats (
  id               uuid primary key default gen_random_uuid(),
  brand_id         uuid not null references public.brands(id) on delete restrict,
  code             text not null,
  name             text not null,                 -- '11 x 5.5 Postcard'
  design_name      text,                          -- 'High Five'
  trim_size        text not null,                 -- '11" x 5.5" flat'
  bleed_size       text,
  delivery         public.delivery_method not null,
  unit_price       numeric(6,4) not null check (unit_price >= 0),
  paper            text,
  ink              text,
  promo_code       text,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (brand_id, code)
);
comment on column public.formats.unit_price is
  'All-in price per piece. PLACEHOLDER values in the seed - replace with real DIS pricing before launch.';

-- Front/back artwork. Files live in Supabase Storage; this is the pointer.
create table public.format_artwork (
  id           uuid primary key default gen_random_uuid(),
  format_id    uuid not null references public.formats(id) on delete cascade,
  face         text not null check (face in ('front','back')),
  storage_path text not null,
  source_pdf   text,
  franchise_id uuid references public.franchises(id) on delete set null,  -- null = brand-wide
  created_at   timestamptz not null default now(),
  unique (format_id, face, franchise_id)
);

-- ---------------------------------------------------------------------------
-- Waves: the shared production calendar
-- ---------------------------------------------------------------------------
create table public.waves (
  id            uuid primary key default gen_random_uuid(),
  brand_id      uuid not null references public.brands(id) on delete restrict,
  name          text not null,
  order_cutoff  timestamptz not null,
  in_home_date  date not null,
  is_open       boolean not null default true,
  created_at    timestamptz not null default now(),
  check (in_home_date >= order_cutoff::date)
);
create index waves_open_idx on public.waves (brand_id, order_cutoff) where is_open;

-- ---------------------------------------------------------------------------
-- Orders
-- ---------------------------------------------------------------------------
create table public.orders (
  id                uuid primary key default gen_random_uuid(),
  order_no          bigint generated by default as identity,
  franchise_id      uuid not null references public.franchises(id) on delete restrict,
  wave_id           uuid not null references public.waves(id) on delete restrict,
  format_id         uuid not null references public.formats(id) on delete restrict,
  status            public.order_status not null default 'draft',
  billing_method    public.billing_method not null,

  -- Price and totals are snapshotted at submit by public.submit_order().
  -- Never trust a client-supplied total.
  unit_price_snapshot numeric(6,4),
  estimated_addresses integer,
  estimated_total     numeric(12,2),

  -- Full criteria payload as submitted, for audit fidelity.
  criteria_snapshot jsonb,

  created_by   uuid not null default public.current_user_id() references public.app_users(id) on delete restrict,
  submitted_by uuid references public.app_users(id) on delete restrict,
  submitted_at timestamptz,
  approved_by  uuid references public.app_users(id) on delete restrict,
  approved_at  timestamptz,
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint submitted_orders_are_priced check (
    status = 'draft'
    or (unit_price_snapshot is not null
        and estimated_addresses is not null
        and estimated_total is not null
        and submitted_at is not null)
  )
);
create index orders_franchise_idx on public.orders (franchise_id, status);
create index orders_wave_idx on public.orders (wave_id);

-- ZIPs on the order, with the estimate computed per ZIP at the time.
create table public.order_zips (
  order_id            uuid not null references public.orders(id) on delete cascade,
  zip                 char(5) not null,
  estimated_addresses integer not null default 0 check (estimated_addresses >= 0),
  primary key (order_id, zip)
);

-- Which bands the operator picked. No rows for a criteria type = no filter.
create table public.order_criteria (
  order_id      uuid not null references public.orders(id) on delete cascade,
  criteria_code text not null references public.criteria_types(code) on delete restrict,
  band_code     text not null,
  primary key (order_id, criteria_code, band_code)
);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger franchises_touch  before update on public.franchises
  for each row execute function public.touch_updated_at();
create trigger formats_touch     before update on public.formats
  for each row execute function public.touch_updated_at();
create trigger orders_touch      before update on public.orders
  for each row execute function public.touch_updated_at();
create trigger zip_profiles_touch before update on public.zip_profiles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere. Policies live in 0002_rls.sql.
-- A table with RLS on and no policy denies all access, which is the safe
-- default if a later migration forgets one.
-- ---------------------------------------------------------------------------
alter table public.staff               enable row level security;
alter table public.brands              enable row level security;
alter table public.franchises          enable row level security;
alter table public.franchise_operators enable row level security;
alter table public.franchise_zips      enable row level security;
alter table public.zip_profiles        enable row level security;
alter table public.criteria_types      enable row level security;
alter table public.criteria_bands      enable row level security;
alter table public.formats             enable row level security;
alter table public.format_artwork      enable row level security;
alter table public.waves               enable row level security;
alter table public.orders              enable row level security;
alter table public.order_zips          enable row level security;
alter table public.order_criteria      enable row level security;
