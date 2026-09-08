-- ============================================================================
-- Server-side audience estimate and order submission
--
-- The estimate lives here, not in the browser, so the number an operator sees,
-- the number on the order, and the number DIS quotes are the same number.
-- ============================================================================

-- Log-logistic CDF. Median sits exactly at the ZIP median; `spread` widens the
-- distribution. Chosen over a normal CDF because it needs no erf() and stays
-- well behaved on strictly positive quantities like income and lot size.
create or replace function public.loglogistic_cdf(
  p_x numeric, p_median numeric, p_spread numeric
) returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when p_x is null      then 1        -- unbounded above
    when p_x <= 0         then 0
    when p_median is null then 1
    else 1 / (1 + exp(-(ln(p_x) - ln(p_median)) / p_spread))
  end;
$$;

-- Share of a ZIP falling inside the selected bands of one criteria type.
-- No bands selected = no filter = 1.0.
create or replace function public.criteria_share(
  p_zip char(5), p_criteria_code text, p_band_codes text[]
) returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v_median numeric;
  v_spread numeric;
  v_col    text;
  v_share  numeric := 0;
  v_row    record;
begin
  if p_band_codes is null or array_length(p_band_codes, 1) is null then
    return 1;
  end if;

  select ct.profile_col, ct.spread into v_col, v_spread
  from public.criteria_types ct where ct.code = p_criteria_code;

  if v_col is null then
    return 1;   -- placeholder criteria that is not wired to the profile yet
  end if;

  execute format('select %I from public.zip_profiles where zip = $1', v_col)
    into v_median using p_zip;

  if v_median is null then
    return 1;
  end if;

  for v_row in
    select cb.lower_bound, cb.upper_bound
    from public.criteria_bands cb
    where cb.criteria_code = p_criteria_code
      and cb.code = any(p_band_codes)
  loop
    v_share := v_share
      + public.loglogistic_cdf(v_row.upper_bound, v_median, v_spread)
      - public.loglogistic_cdf(coalesce(v_row.lower_bound, 0), v_median, v_spread);
  end loop;

  return greatest(0, least(1, v_share));
end;
$$;

-- Estimated mailable addresses in one ZIP, given the order's criteria.
-- Owner-occupied only: lawn care does not mail renters.
create or replace function public.estimate_zip_addresses(
  p_zip char(5), p_income_bands text[], p_lot_bands text[]
) returns integer
language sql
stable
set search_path = ''
as $$
  select coalesce(
    round(
      zp.households
      * zp.owner_occ_share
      * public.criteria_share(p_zip, 'household_income', p_income_bands)
      * public.criteria_share(p_zip, 'lot_size',         p_lot_bands)
    )::integer, 0)
  from public.zip_profiles zp
  where zp.zip = p_zip;
$$;

-- Recompute every ZIP line on a draft order and return the total.
create or replace function public.reprice_order(p_order uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_income text[];
  v_lot    text[];
  v_total  integer := 0;
begin
  if not public.order_is_editable(p_order) then
    raise exception 'Order % is not editable by you', p_order using errcode = 'insufficient_privilege';
  end if;

  select array_agg(band_code) into v_income
    from public.order_criteria where order_id = p_order and criteria_code = 'household_income';
  select array_agg(band_code) into v_lot
    from public.order_criteria where order_id = p_order and criteria_code = 'lot_size';

  update public.order_zips oz
     set estimated_addresses = public.estimate_zip_addresses(oz.zip, v_income, v_lot)
   where oz.order_id = p_order;

  select coalesce(sum(estimated_addresses), 0) into v_total
    from public.order_zips where order_id = p_order;

  return v_total;
end;
$$;

-- ---------------------------------------------------------------------------
-- Submission. The only way an order leaves 'draft' on the operator side.
-- Snapshots the price so a later price change never rewrites history.
-- ---------------------------------------------------------------------------
create or replace function public.submit_order(p_order uuid)
returns public.orders
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order   public.orders;
  v_format  public.formats;
  v_wave    public.waves;
  v_count   integer;
  v_income  text[];
  v_lot     text[];
  v_result  public.orders;
begin
  select * into v_order from public.orders where id = p_order;
  if v_order.id is null then
    raise exception 'Order not found' using errcode = 'no_data_found';
  end if;

  if not (public.is_staff() or public.is_operator_of(v_order.franchise_id)) then
    raise exception 'Not your order' using errcode = 'insufficient_privilege';
  end if;

  if v_order.status <> 'draft' then
    raise exception 'Order % is already %', p_order, v_order.status using errcode = 'check_violation';
  end if;

  select * into v_format from public.formats where id = v_order.format_id;
  if not v_format.is_active then
    raise exception 'Format % is not available', v_format.code using errcode = 'check_violation';
  end if;

  select * into v_wave from public.waves where id = v_order.wave_id;
  if not v_wave.is_open then
    raise exception 'That wave is closed' using errcode = 'check_violation';
  end if;
  if now() > v_wave.order_cutoff then
    raise exception 'The cutoff for % passed at %', v_wave.name, v_wave.order_cutoff
      using errcode = 'check_violation';
  end if;

  v_count := public.reprice_order(p_order);
  if v_count <= 0 then
    raise exception 'Nothing to send: no addresses match this ZIP and criteria selection'
      using errcode = 'check_violation';
  end if;

  select array_agg(band_code) into v_income
    from public.order_criteria where order_id = p_order and criteria_code = 'household_income';
  select array_agg(band_code) into v_lot
    from public.order_criteria where order_id = p_order and criteria_code = 'lot_size';

  -- Mark this transaction as a sanctioned submission so guard_order_transition
  -- will permit the status and pricing write. is_local = true, so it dies with
  -- the transaction and never leaks into another request.
  perform set_config('app.submitting_order', p_order::text, true);

  update public.orders o
     set status              = 'submitted',
         submitted_by        = public.current_user_id(),
         submitted_at        = now(),
         unit_price_snapshot = v_format.unit_price,
         estimated_addresses = v_count,
         estimated_total     = round(v_count * v_format.unit_price, 2),
         criteria_snapshot   = jsonb_build_object(
           'household_income', coalesce(to_jsonb(v_income), '[]'::jsonb),
           'lot_size',         coalesce(to_jsonb(v_lot),    '[]'::jsonb),
           'zips', (select coalesce(jsonb_agg(jsonb_build_object(
                             'zip', zip, 'addresses', estimated_addresses) order by zip), '[]'::jsonb)
                    from public.order_zips where order_id = p_order),
           'format', jsonb_build_object('code', v_format.code, 'name', v_format.name,
                                        'delivery', v_format.delivery, 'unit_price', v_format.unit_price),
           'submitted_at', now()
         )
   where o.id = p_order
  returning * into v_result;

  return v_result;
end;
$$;

-- Postgres grants EXECUTE to PUBLIC on every new function. Revoke first,
-- then hand execute back to signed-in users only.
revoke all on function public.submit_order(uuid)                              from public;
revoke all on function public.reprice_order(uuid)                             from public;
revoke all on function public.estimate_zip_addresses(char, text[], text[])    from public;
revoke all on function public.criteria_share(char, text, text[])              from public;
revoke all on function public.loglogistic_cdf(numeric, numeric, numeric)      from public;
revoke all on function public.current_user_id()                               from public;
revoke all on function public.is_staff()                                      from public;
revoke all on function public.is_operator_of(uuid)                            from public;
revoke all on function public.my_franchise_ids()                              from public;
revoke all on function public.order_is_editable(uuid)                         from public;
revoke all on function public.order_is_visible(uuid)                          from public;

grant execute on function public.submit_order(uuid)                           to authenticated;
grant execute on function public.reprice_order(uuid)                          to authenticated;
grant execute on function public.estimate_zip_addresses(char, text[], text[]) to authenticated;
grant execute on function public.criteria_share(char, text, text[])           to authenticated;
grant execute on function public.loglogistic_cdf(numeric, numeric, numeric)   to authenticated;
grant execute on function public.current_user_id()                            to authenticated;
grant execute on function public.is_staff()                                   to authenticated;
grant execute on function public.is_operator_of(uuid)                         to authenticated;
grant execute on function public.my_franchise_ids()                           to authenticated;
grant execute on function public.order_is_editable(uuid)                      to authenticated;
grant execute on function public.order_is_visible(uuid)                       to authenticated;
