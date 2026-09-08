-- ============================================================================
-- Hand-delivered formats have no address list
--
-- Door hangers are walked door to door, so there is no ZIP selection, no
-- criteria, and no address file. The quantity is stated by the operator
-- instead of derived from a household estimate.
--
-- Before this migration submit_order() always priced from order_zips and
-- raised "Nothing to send" when there were none - which rejected every door
-- hanger order.
-- ============================================================================

alter table public.orders
  add column if not exists quantity integer
    check (quantity is null or quantity >= 500);

comment on column public.orders.quantity is
  'Pieces requested. Used for hand-delivered formats, where there is no address file to count. Null for mailed orders, which are counted from order_zips.';

-- ---------------------------------------------------------------------------
-- submit_order: price from the address estimate when mailed, from the stated
-- quantity when hand-delivered.
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
  v_mailed  boolean;
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

  v_mailed := (v_format.delivery = 'usps_mail');

  if v_mailed then
    v_count := public.reprice_order(p_order);
    if v_count <= 0 then
      raise exception 'Nothing to send: no addresses match this ZIP and criteria selection'
        using errcode = 'check_violation';
    end if;

    select array_agg(band_code) into v_income
      from public.order_criteria where order_id = p_order and criteria_code = 'household_income';
    select array_agg(band_code) into v_lot
      from public.order_criteria where order_id = p_order and criteria_code = 'lot_size';
  else
    -- Hand-delivered: the operator states the run size. Nothing to estimate,
    -- and any stray ZIP or criteria rows are meaningless here.
    v_count := v_order.quantity;
    if v_count is null or v_count < 500 then
      raise exception 'Tell us how many pieces you want out (minimum 500)'
        using errcode = 'check_violation';
    end if;

    if exists (select 1 from public.order_zips where order_id = p_order) then
      raise exception 'A hand-delivered order has no address list; remove the ZIP rows'
        using errcode = 'check_violation';
    end if;
  end if;

  perform set_config('app.submitting_order', p_order::text, true);

  update public.orders o
     set status              = 'submitted',
         submitted_by        = public.current_user_id(),
         submitted_at        = now(),
         unit_price_snapshot = v_format.unit_price,
         estimated_addresses = v_count,
         estimated_total     = round(v_count * v_format.unit_price, 2),
         criteria_snapshot   = case when v_mailed then jsonb_build_object(
             'delivery',         'usps_mail',
             'household_income', coalesce(to_jsonb(v_income), '[]'::jsonb),
             'lot_size',         coalesce(to_jsonb(v_lot),    '[]'::jsonb),
             'zips', (select coalesce(jsonb_agg(jsonb_build_object(
                               'zip', zip, 'addresses', estimated_addresses) order by zip), '[]'::jsonb)
                      from public.order_zips where order_id = p_order),
             'format', jsonb_build_object('code', v_format.code, 'name', v_format.name,
                                          'delivery', v_format.delivery, 'unit_price', v_format.unit_price),
             'submitted_at', now()
           )
           else jsonb_build_object(
             'delivery',  'hand_delivered',
             'quantity',  v_count,
             'routing',   'walk routes planned by the mail house',
             'format', jsonb_build_object('code', v_format.code, 'name', v_format.name,
                                          'delivery', v_format.delivery, 'unit_price', v_format.unit_price),
             'submitted_at', now()
           ) end
   where o.id = p_order
  returning * into v_result;

  return v_result;
end;
$$;

revoke all on function public.submit_order(uuid) from public;
grant execute on function public.submit_order(uuid) to authenticated;

-- An operator may set quantity on their own draft; the guard already blocks
-- them from touching pricing and status, and quantity is not either of those.
