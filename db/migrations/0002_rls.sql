-- ============================================================================
-- Row-level security policies
--
-- Two audiences:
--   staff     - DIS Direct employees, full read/write
--   operator  - a franchisee, scoped to franchises they actively belong to
--
-- Reference data (ZIP profiles, criteria, formats, waves) is readable by any
-- signed-in user and writable only by staff.
--
-- Nothing is granted to `anon`. An unauthenticated visitor sees nothing at all.
-- ============================================================================

-- Baseline grants. RLS still filters rows; these just open the tables to the
-- authenticated role so policies get a chance to run.
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;

-- ---------------------------------------------------------------------------
-- app_users: staff may read everyone (self-read policy is in 0000)
-- ---------------------------------------------------------------------------
create policy app_users_staff_read on public.app_users
  for select to authenticated
  using (public.is_staff());

create policy app_users_staff_write on public.app_users
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- staff
-- ---------------------------------------------------------------------------
create policy staff_self_read on public.staff
  for select to authenticated
  using (user_id = public.current_user_id() or public.is_staff());

create policy staff_manage on public.staff
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- brands / franchises
-- ---------------------------------------------------------------------------
create policy brands_read on public.brands
  for select to authenticated using (true);

create policy brands_write on public.brands
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- An operator sees only their own franchises - not the rest of the network.
create policy franchises_read on public.franchises
  for select to authenticated
  using (public.is_staff() or id in (select public.my_franchise_ids()));

create policy franchises_write on public.franchises
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- franchise_operators
--
-- An operator may see who else is on their own franchise, and nothing about
-- any other franchise. Only staff can grant or revoke membership - an operator
-- must never be able to add themselves to another franchise.
-- ---------------------------------------------------------------------------
create policy franchise_operators_read on public.franchise_operators
  for select to authenticated
  using (public.is_staff() or franchise_id in (select public.my_franchise_ids()));

create policy franchise_operators_write on public.franchise_operators
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- territory
-- ---------------------------------------------------------------------------
create policy franchise_zips_read on public.franchise_zips
  for select to authenticated
  using (public.is_staff() or franchise_id in (select public.my_franchise_ids()));

create policy franchise_zips_write on public.franchise_zips
  for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- reference data: read for all signed-in, write staff only
-- ---------------------------------------------------------------------------
create policy zip_profiles_read on public.zip_profiles
  for select to authenticated using (true);
create policy zip_profiles_write on public.zip_profiles
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

create policy criteria_types_read on public.criteria_types
  for select to authenticated using (true);
create policy criteria_types_write on public.criteria_types
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

create policy criteria_bands_read on public.criteria_bands
  for select to authenticated using (true);
create policy criteria_bands_write on public.criteria_bands
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

create policy formats_read on public.formats
  for select to authenticated using (is_active or public.is_staff());
create policy formats_write on public.formats
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- Brand-wide artwork is visible to everyone; branch-specific artwork only to
-- that branch.
create policy format_artwork_read on public.format_artwork
  for select to authenticated
  using (
    public.is_staff()
    or franchise_id is null
    or franchise_id in (select public.my_franchise_ids())
  );
create policy format_artwork_write on public.format_artwork
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

create policy waves_read on public.waves
  for select to authenticated using (true);
create policy waves_write on public.waves
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------------------
-- orders
--
-- Read   : own franchise, or staff.
-- Insert : own franchise only, and only as a draft. status/pricing columns are
--          not the client's to set - submit_order() fills them.
-- Update : own franchise AND still a draft. Once submitted an operator can no
--          longer edit; only staff can move it through production.
-- Delete : own draft only. Submitted orders are records and are never deleted;
--          cancel them instead.
-- ---------------------------------------------------------------------------
grant insert, update, delete on public.orders, public.order_zips, public.order_criteria to authenticated;

create policy orders_read on public.orders
  for select to authenticated
  using (public.is_staff() or franchise_id in (select public.my_franchise_ids()));

create policy orders_insert on public.orders
  for insert to authenticated
  with check (
    public.is_staff()
    or (
      franchise_id in (select public.my_franchise_ids())
      and status = 'draft'
      and created_by = public.current_user_id()
      and submitted_at is null
      and approved_by is null
      and unit_price_snapshot is null
      and estimated_total is null
    )
  );

create policy orders_update_draft on public.orders
  for update to authenticated
  using (
    public.is_staff()
    or (franchise_id in (select public.my_franchise_ids()) and status = 'draft')
  )
  with check (
    public.is_staff()
    or (
      franchise_id in (select public.my_franchise_ids())
      -- an operator's own UPDATE can only ever leave the row as a draft.
      -- Promotion to 'submitted' happens exclusively inside submit_order(),
      -- which is security definer and therefore not subject to this policy.
      and status = 'draft'
    )
  );

create policy orders_delete_draft on public.orders
  for delete to authenticated
  using (
    public.is_staff()
    or (franchise_id in (select public.my_franchise_ids()) and status = 'draft')
  );

-- ---------------------------------------------------------------------------
-- order children - editable only while the parent order is a draft
-- ---------------------------------------------------------------------------
create or replace function public.order_is_editable(p_order uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order
      and (
        public.is_staff()
        or (o.status = 'draft' and public.is_operator_of(o.franchise_id))
      )
  );
$$;

create or replace function public.order_is_visible(p_order uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.orders o
    where o.id = p_order
      and (public.is_staff() or public.is_operator_of(o.franchise_id))
  );
$$;

create policy order_zips_read on public.order_zips
  for select to authenticated using (public.order_is_visible(order_id));
create policy order_zips_write on public.order_zips
  for all to authenticated
  using (public.order_is_editable(order_id))
  with check (public.order_is_editable(order_id));

create policy order_criteria_read on public.order_criteria
  for select to authenticated using (public.order_is_visible(order_id));
create policy order_criteria_write on public.order_criteria
  for all to authenticated
  using (public.order_is_editable(order_id))
  with check (public.order_is_editable(order_id));

-- ---------------------------------------------------------------------------
-- Guard rails that RLS alone cannot express
-- ---------------------------------------------------------------------------

-- An operator must not move an order past 'submitted', nor rewrite pricing.
create or replace function public.guard_order_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- submit_order() sets this for the duration of its transaction. Nothing
  -- reachable over the API can set it, so it cannot be forged by a client.
  v_submitting text := current_setting('app.submitting_order', true);
begin
  if public.is_staff() then
    return new;
  end if;

  if v_submitting is not null and v_submitting = old.id::text then
    return new;   -- the sanctioned draft -> submitted transition
  end if;

  if new.status is distinct from old.status then
    raise exception 'Order status is changed through submit_order(), not by direct update'
      using errcode = 'check_violation';
  end if;

  if new.franchise_id <> old.franchise_id then
    raise exception 'An order cannot be moved between franchises'
      using errcode = 'check_violation';
  end if;

  if new.unit_price_snapshot is distinct from old.unit_price_snapshot
     or new.estimated_addresses is distinct from old.estimated_addresses
     or new.estimated_total is distinct from old.estimated_total
     or new.submitted_at is distinct from old.submitted_at
     or new.submitted_by is distinct from old.submitted_by
     or new.approved_at is distinct from old.approved_at
     or new.approved_by is distinct from old.approved_by then
    raise exception 'Pricing and approval fields are set by the server, not the client'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger orders_guard_transition
  before update on public.orders
  for each row execute function public.guard_order_transition();

-- A ZIP on an order must be inside that franchise's agreed territory.
create or replace function public.guard_order_zip_in_territory()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_franchise uuid;
begin
  select o.franchise_id into v_franchise from public.orders o where o.id = new.order_id;

  if public.is_staff() then
    return new;
  end if;

  if not exists (
    select 1 from public.franchise_zips fz
    where fz.franchise_id = v_franchise and fz.zip = new.zip
  ) then
    raise exception 'ZIP % is not in this franchise territory. Ask DIS to add it.', new.zip
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger order_zips_guard_territory
  before insert or update on public.order_zips
  for each row execute function public.guard_order_zip_in_territory();
