-- ============================================================================
-- Reference seed
--
-- WHAT IS REAL HERE
--   format names, trim sizes, delivery method, promo codes, Aurora phone/web
--   (taken from the production PDFs 28633-1, 28604-1, 28607-1)
--
-- WHAT IS A PLACEHOLDER - replace before launch
--   * formats.unit_price      - guessed. Real DIS all-in pricing needed.
--   * zip_profiles.*          - modelled DuPage-area estimates, source='estimate'.
--                               Replace with real counts on first list pull.
--   * the two reserved criteria types, which ship is_active = false
-- ============================================================================

-- Brand -------------------------------------------------------------------
insert into public.brands (name, slug) values ('Weed Man', 'weed-man');

-- Criteria types ----------------------------------------------------------
insert into public.criteria_types (code, label, unit, profile_col, spread, sort_order, is_active) values
  ('household_income', 'Household income', 'usd',  'median_income',   0.460, 1, true),
  ('lot_size',         'Lot size',         'sqft', 'median_lot_sqft', 0.400, 2, true),
  -- Reserved slots. Wire profile_col + spread when the list source is confirmed.
  ('home_value',          'Home value',          'usd',  null, null, 3, false),
  ('length_of_residence', 'Length of residence', 'years',null, null, 4, false),
  ('property_type',       'Property type',       null,   null, null, 5, false);

insert into public.criteria_bands (criteria_code, code, label, lower_bound, upper_bound, sort_order) values
  ('household_income','i1','Under $50k',      null,   50000,  1),
  ('household_income','i2','$50k-$75k',       50000,  75000,  2),
  ('household_income','i3','$75k-$100k',      75000,  100000, 3),
  ('household_income','i4','$100k-$150k',     100000, 150000, 4),
  ('household_income','i5','$150k-$200k',     150000, 200000, 5),
  ('household_income','i6','$200k+',          200000, null,   6),
  ('lot_size','l1','Under 5,000 sq ft',       null,   5000,   1),
  ('lot_size','l2','5,000-8,000 sq ft',       5000,   8000,   2),
  ('lot_size','l3','8,000-12,000 sq ft',      8000,   12000,  3),
  ('lot_size','l4','12,000-20,000 sq ft',     12000,  20000,  4),
  ('lot_size','l5','20,000+ sq ft',           20000,  null,   5);

-- Formats -----------------------------------------------------------------
-- unit_price values are PLACEHOLDERS.
insert into public.formats
  (brand_id, code, name, design_name, trim_size, bleed_size, delivery, unit_price, paper, ink, promo_code)
select b.id, v.code, v.name, v.design_name, v.trim, v.bleed, v.delivery::public.delivery_method,
       v.price, v.paper, v.ink, v.promo
from public.brands b, (values
  ('pc-11x55',  '11 x 5.5 Postcard',  null,
   '11" x 5.5" flat', '11.25" x 5.75" with bleed', 'usps_mail',      0.4600,
   '14 pt C2S', '4/4 process', 'DM29'),
  ('dh-4x11-a', '4 x 11 Door Hanger', 'High Five',
   '4" x 11"',  '4.25" x 11.25" with bleed', 'hand_delivered', 0.3800,
   '14 pt C2S, die-cut hook', '4/4 process', 'DH29'),
  ('dh-4x11-b', '4 x 11 Door Hanger', 'Lawn Care Win',
   '4" x 11"',  '4.25" x 11.25" with bleed', 'hand_delivered', 0.3800,
   '14 pt C2S, die-cut hook', '4/4 process', 'DH29')
) as v(code, name, design_name, trim, bleed, delivery, price, paper, ink, promo)
where b.slug = 'weed-man';

-- Artwork pointers. Upload the rendered faces to Storage at these paths.
insert into public.format_artwork (format_id, face, storage_path, source_pdf)
select f.id, x.face, 'artwork/' || f.code || '-' || x.face || '.jpg', x.src
from public.formats f
join (values
  ('pc-11x55',  'front', '28633.1-28633-1-weedmanaurora.pdf p1'),
  ('pc-11x55',  'back',  '28633.1-28633-1-weedmanaurora.pdf p2'),
  ('dh-4x11-a', 'front', '28604.1-28604-1-weedmanmuskegon.pdf p1'),
  ('dh-4x11-a', 'back',  '28604.1-28604-1-weedmanmuskegon.pdf p2'),
  ('dh-4x11-b', 'front', '28607.1-28607-1-weedmanlibertyville.pdf p1'),
  ('dh-4x11-b', 'back',  '28607.1-28607-1-weedmanlibertyville.pdf p2')
) as x(code, face, src) on x.code = f.code;

-- ZIP household universe --------------------------------------------------
-- source='estimate' on every row: these are modelled, not a list pull.
insert into public.zip_profiles
  (zip, city, state, households, owner_occ_share, median_income, median_lot_sqft, source) values
  ('60540','NAPERVILLE','IL',16400,0.810,132000, 9600,'estimate'),
  ('60563','NAPERVILLE','IL',11200,0.740,110000, 8200,'estimate'),
  ('60564','NAPERVILLE','IL',13900,0.860,158000,11200,'estimate'),
  ('60565','NAPERVILLE','IL',12600,0.830,141000,10100,'estimate'),
  ('60532','LISLE','IL',       9800,0.660, 97000, 7400,'estimate'),
  ('60517','WOODRIDGE','IL',  10400,0.690, 94000, 7900,'estimate'),
  ('60555','WARRENVILLE','IL', 5600,0.710, 99000, 8600,'estimate'),
  ('60559','WESTMONT','IL',    8100,0.630, 91000, 6900,'estimate'),
  ('60561','DARIEN','IL',      7700,0.800,118000, 9100,'estimate'),
  ('60187','WHEATON','IL',    10900,0.770,124000, 9800,'estimate');

-- A first franchise + its territory --------------------------------------
insert into public.franchises (brand_id, name, city, state, phone, web, home_zip)
select id, 'Weed Man Aurora', 'Aurora', 'IL', '630-701-7575', 'WeedMan.com', '60540'
from public.brands where slug = 'weed-man';

insert into public.franchise_zips (franchise_id, zip)
select f.id, z.zip
from public.franchises f, public.zip_profiles z
where f.name = 'Weed Man Aurora';

-- An open wave ------------------------------------------------------------
insert into public.waves (brand_id, name, order_cutoff, in_home_date, is_open)
select id, 'Fall Wave 1', timestamptz '2026-09-15 17:00:00-05', date '2026-09-16', true
from public.brands where slug = 'weed-man';
