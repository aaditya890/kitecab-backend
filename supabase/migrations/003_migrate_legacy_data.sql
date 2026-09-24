-- =====================================================================
-- KiteCab v2 — copy legacy JSON data (table `kitecab`) into new tables
--
-- * Re-runnable until launch: it EMPTIES the new tables first, then
--   rebuilds them from the legacy rows. Run it one final time at cutover.
-- * Never modifies the legacy `kitecab` or `payments` tables.
-- * Uses your data and prices exactly; only cleans obvious junk:
--     - trims spaces, 'Arrah(BR)' -> 'Arrah (BR)'
--     - drops empty rows and testingPickup/testingDrop
--     - duplicate route (same pickup+drop): keeps the most recently added one
--     - car/booking type spelling ('Suv', 'Sedam', 'Round Trip ') unified
--     - enquiry mobile '0000000000' / invalid -> NULL
--     - duplicate booking id: 2nd copy gets a new id (legacy_id keeps the old)
--     - passengers outside 1..20 (people typed phone numbers there) -> 1
-- =====================================================================
begin;

-- ---------- helpers (temporary, dropped at end of session) -----------
create or replace function pg_temp.to_int(t text) returns int language sql immutable as $$
  select case when trim(coalesce(t, '')) ~ '^\d{1,9}(\.\d+)?$' then round(trim(t)::numeric)::int end
$$;

create or replace function pg_temp.place(t text) returns text language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(trim(coalesce(t, '')), '\s*\(', ' ('), '\s+', ' ', 'g'), '')
$$;

create or replace function pg_temp.car(t text) returns public.car_type language sql immutable as $$
  select case
    when lower(trim(t)) like 'suv%'   then 'SUV'
    when lower(trim(t)) like 'sed%'   then 'Sedan'
    else 'Hatchback' end::public.car_type
$$;

create or replace function pg_temp.btype(t text) returns public.booking_type language sql immutable as $$
  select case
    when lower(t) like '%rental%' then 'local-rental'
    when lower(t) like 'round%'   then 'round-trip'
    else 'oneway' end::public.booking_type
$$;

-- 'Thu Sep 24 2026' (new) or '2024-11-28T18:30:00.000Z' (IST midnight saved as UTC)
create or replace function pg_temp.pickup_date(t text) returns date language sql immutable as $$
  select case
    when t ~ '^\d{4}-\d{2}-\d{2}T' then (t::timestamptz at time zone 'Asia/Kolkata')::date
    when t ~ '^[A-Za-z]{3} [A-Za-z]{3} \d{2} \d{4}$' then to_date(substr(t, 5), 'Mon DD YYYY')
  end
$$;

create or replace function pg_temp.mobile(t text) returns text language sql immutable as $$
  select case when trim(coalesce(t, '')) ~ '^[6-9]\d{9}$' then trim(t) end
$$;

-- enquiry date/time came in many shapes: '1/5/2026' '01/05/2026' '2026-05-01'
-- and '08:53:38' '8:53:38 PM' '04:51 pm' ... -> IST timestamp (NULL if unreadable)
create or replace function pg_temp.enquiry_ts(d text, t text) returns timestamptz language plpgsql immutable as $$
declare dm text[]; tm text[]; a int; b int; y int; h int; mi int; se int; dt date;
begin
  if d ~ '^\d{4}-\d{2}-\d{2}' then
    dt := substr(d, 1, 10)::date;
  else
    dm := regexp_match(trim(d), '^(\d{1,2})/(\d{1,2})/(\d{4})$');
    if dm is null then return null; end if;
    a := dm[1]::int; b := dm[2]::int; y := dm[3]::int;
    if b > 12 then dt := make_date(y, a, b);       -- clearly M/D/Y
    else
      dt := make_date(y, b, a);                    -- D/M/Y (India)
      -- a future date means the browser saved it as M/D/Y
      if dt > current_date and a <= 12 then dt := make_date(y, a, b); end if;
    end if;
  end if;
  tm := regexp_match(trim(coalesce(t, '')), '^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?$');
  if tm is null then return dt::timestamp at time zone 'Asia/Kolkata'; end if;
  h := tm[1]::int; mi := tm[2]::int; se := coalesce(tm[3], '0')::int;
  if lower(tm[4]) = 'pm' and h < 12 then h := h + 12; end if;
  if lower(tm[4]) = 'am' and h = 12 then h := 0; end if;
  return (dt + make_time(h, mi, se)) at time zone 'Asia/Kolkata';
exception when others then
  return null;
end $$;

create or replace function pg_temp.legacy(k text) returns setof jsonb language sql stable as $$
  select e from public.kitecab k2, jsonb_array_elements(k2.value) with ordinality as x(e, n)
  where k2.key = k order by n
$$;

-- ---------- reset new tables -----------------------------------------
truncate public.booking_status_history, public.bookings, public.customers,
         public.enquiries, public.routes, public.rental_packages, public.locations
  restart identity cascade;

alter table public.bookings disable trigger bookings_status_log;

-- ---------- locations ------------------------------------------------
with raw as (
  select pg_temp.place(e->>'pickup') as name from pg_temp.legacy('locationPrices') e
  union
  select pg_temp.place(e->>'dropoff') from pg_temp.legacy('locationPrices') e
)
insert into public.locations (name, slug, state, is_featured, sort_order)
select name,
       public.slugify(name),
       coalesce(substring(name from '\(([A-Z]{2})\)$'), 'CG'),
       name in ('Raipur', 'Bilaspur', 'Durg', 'Bhilai', 'Raigarh', 'Nagpur (MH)'),
       case name when 'Raipur' then 1 when 'Bilaspur' then 2 when 'Durg' then 3
                 when 'Bhilai' then 4 when 'Raigarh' then 5 when 'Nagpur (MH)' then 6 else 100 end
from raw
where name is not null and name not ilike 'testing%'
order by name;

-- ---------- routes ---------------------------------------------------
with src as (
  select e, row_number() over () as n from pg_temp.legacy('locationPrices') e
), clean as (
  select distinct on (f.id, t.id)
         f.id as from_id, t.id as to_id,
         pg_temp.to_int(e->>'distance')   as distance_km,
         pg_temp.to_int(e->>'price')      as hatchback_price,
         pg_temp.to_int(e->>'sedanPrice') as sedan_price,
         pg_temp.to_int(e->>'suvPrice')   as suv_price,
         coalesce((e->>'active')::boolean, true) as is_active,
         (e->>'id')::bigint as legacy_id
  from src
  join public.locations f on f.name = pg_temp.place(e->>'pickup')
  join public.locations t on t.name = pg_temp.place(e->>'dropoff')
  where f.id <> t.id
  order by f.id, t.id, n desc                      -- latest entry wins
)
insert into public.routes (from_location_id, to_location_id, distance_km,
                           hatchback_price, sedan_price, suv_price, is_active, legacy_id)
select from_id, to_id, distance_km, hatchback_price, sedan_price, suv_price, is_active, legacy_id
from clean
where distance_km > 0 and hatchback_price > 0 and sedan_price > 0 and suv_price > 0;

-- ---------- rental packages ------------------------------------------
insert into public.rental_packages (hours, km, hatchback_price, sedan_price, suv_price, legacy_id)
select pg_temp.to_int(substring(e->>'time' from '\d+')),
       pg_temp.to_int(e->>'distance'),
       pg_temp.to_int(e->>'hatchbackPrice'),
       pg_temp.to_int(e->>'sedanPrice'),
       pg_temp.to_int(e->>'suvPrice'),
       (e->>'id')::bigint
from pg_temp.legacy('rentalPackages') e
order by 1;

-- ---------- bookings -------------------------------------------------
create temp table legacy_bookings on commit drop as
select (e->>'id')::bigint as legacy_id,
       row_number() over (partition by e->>'id' order by n) as copy_no,
       n,
       e->'customerDetail' as c,
       e->'bookingDetail'  as b
from (select e, row_number() over () as n from pg_temp.legacy('customersRecord') e) s;

create temp table booking_rows on commit drop as
select lb.legacy_id, lb.copy_no, lb.n,
       pg_temp.btype(b->>'bookingType')                         as booking_type,
       pg_temp.car(b->>'carType')                               as car_type,
       coalesce(pg_temp.place(b->>'pickupLocation'), '-')       as pickup_location,
       pg_temp.place(b->>'dropLocation')                        as drop_location,
       nullif(trim(b->>'package'), '')                          as rental_package,
       nullif(trim(b->>'waitingTime'), '')                      as waiting_time,
       pg_temp.to_int(b->>'approxDistance')                     as approx_distance_km,
       pg_temp.to_int(b->>'distance')                           as distance_km,
       coalesce(pg_temp.to_int(b->>'price'), 0)                 as fare,
       coalesce(nullif(trim(c->>'fullName'), ''), '-')          as customer_name,
       trim(coalesce(c->>'mobileNumber', ''))                   as mobile,
       nullif(trim(c->>'email'), '')                            as email,
       case when pg_temp.to_int(c->>'numberOfPassengers') between 1 and 20
            then pg_temp.to_int(c->>'numberOfPassengers') else 1 end  as passengers,
       coalesce(nullif(trim(c->>'pickupAddress'), ''), '-')     as pickup_address,
       pg_temp.pickup_date(c->>'pickupDate')                    as pickup_date,
       coalesce(nullif(trim(c->>'pickupTime'), ''), '-')        as pickup_time
from legacy_bookings lb;

-- first copy keeps its original id (invoice numbers stay the same)
insert into public.bookings (id, booking_type, car_type, pickup_location, drop_location,
       rental_package, waiting_time, approx_distance_km, distance_km, fare,
       customer_name, mobile, email, passengers, pickup_address, pickup_date, pickup_time,
       advance_amount, legacy_id, created_at)
overriding system value
select r.legacy_id, r.booking_type, r.car_type, r.pickup_location, r.drop_location,
       r.rental_package, r.waiting_time, r.approx_distance_km, r.distance_km, r.fare,
       r.customer_name, r.mobile, r.email, r.passengers, r.pickup_address,
       coalesce(r.pickup_date, (p.created_at at time zone 'Asia/Kolkata')::date, date '2024-11-01'),
       r.pickup_time, p.advance_amount, r.legacy_id,
       coalesce(p.created_at, (coalesce(r.pickup_date, date '2024-11-01'))::timestamp at time zone 'Asia/Kolkata')
from booking_rows r
left join lateral (select pm.created_at, pm.advance_amount from public.payments pm
                   where pm.booking_id::bigint = r.legacy_id
                   order by pm.created_at desc limit 1) p on true
where r.copy_no = 1
order by r.n;

select setval(pg_get_serial_sequence('public.bookings', 'id'),
              greatest((select max(id) from public.bookings), 999969));

-- duplicate ids get a fresh id
insert into public.bookings (booking_type, car_type, pickup_location, drop_location,
       rental_package, waiting_time, approx_distance_km, distance_km, fare,
       customer_name, mobile, email, passengers, pickup_address, pickup_date, pickup_time, legacy_id)
select booking_type, car_type, pickup_location, drop_location,
       rental_package, waiting_time, approx_distance_km, distance_km, fare,
       customer_name, mobile, email, passengers, pickup_address,
       coalesce(pickup_date, date '2024-11-01'), pickup_time, legacy_id
from booking_rows where copy_no > 1 order by n;

-- link rental packages & routes where the names match
update public.bookings b set rental_package_id = rp.id
from public.rental_packages rp
where b.booking_type = 'local-rental'
  and regexp_replace(lower(b.rental_package), '\s', '', 'g') = rp.hours || 'hour' || rp.km || 'km';

update public.bookings b set route_id = r.id
from public.routes r
join public.locations f on f.id = r.from_location_id
join public.locations t on t.id = r.to_location_id
where b.booking_type = 'oneway' and f.name = b.pickup_location and t.name = b.drop_location;

-- ---------- customers (one per mobile, latest name/email) -------------
insert into public.customers (full_name, mobile, email, created_at)
select distinct on (mobile) customer_name, mobile, email, created_at
from public.bookings
where mobile ~ '^\d{10}$'
order by mobile, id desc;

update public.customers c set created_at = first.created_at
from (select mobile, min(created_at) as created_at from public.bookings group by mobile) first
where first.mobile = c.mobile;

update public.bookings b set customer_id = c.id
from public.customers c where c.mobile = b.mobile;

-- ---------- enquiries ------------------------------------------------
insert into public.enquiries (service_type, pickup, drop_or_package, mobile, created_at, legacy_id)
select case when lower(e->>'dropLocationOrPackages') ~ '\d+\s*hour' then 'local-rental'::public.booking_type end,
       coalesce(pg_temp.place(e->>'pickupLocation'), '-'),
       pg_temp.place(e->>'dropLocationOrPackages'),
       pg_temp.mobile(e->>'mobileNumber'),
       coalesce(pg_temp.enquiry_ts(e->>'date', e->>'time'), now()),
       pg_temp.to_int(e->>'id')
from pg_temp.legacy('enquiry') e;

alter table public.bookings enable trigger bookings_status_log;

commit;

-- ---------- report ---------------------------------------------------
select 'locations' as tbl, count(*) from public.locations
union all select 'routes', count(*) from public.routes
union all select 'rental_packages', count(*) from public.rental_packages
union all select 'bookings', count(*) from public.bookings
union all select 'customers', count(*) from public.customers
union all select 'enquiries', count(*) from public.enquiries
union all select 'enquiries with invalid mobile (NULL)', count(*) from public.enquiries where mobile is null;
