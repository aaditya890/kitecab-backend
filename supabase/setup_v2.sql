-- =====================================================================
-- KiteCab v2 — ONE-TIME SETUP (paste everything into Supabase SQL Editor, click Run)
--
-- What it does
--   * Creates NEW tables for the new website (bookings, customers, routes ...).
--   * Copies your data from the live `kitecab` and `payments` tables (READ only).
--
-- What it NEVER does
--   * Never changes, deletes or adds anything to `kitecab` or `payments`
--     (no columns, indexes, policies, grants or triggers) — the live site is unaffected.
--
-- Safety
--   * Each part runs in a transaction: if anything fails, that part changes nothing.
--   * Undo everything with rollback_v2.sql.
--   * Prove the live tables are untouched with check_live_tables.sql (before/after).
--
-- Generated from supabase/migrations/001..004 — edit those, not this file.
-- =====================================================================

-- ##################### 001_schema.sql #####################
-- =====================================================================
-- KiteCab v2 — core schema
-- Run in Supabase SQL editor (or `supabase db push`).
-- Creates NEW objects only. The live tables `kitecab` and `payments` are
-- never altered (no columns, indexes, grants or policies are added to them).
-- =====================================================================
begin;

-- ---------- enums ----------------------------------------------------
create type public.booking_type   as enum ('oneway', 'round-trip', 'local-rental');
create type public.car_type       as enum ('Hatchback', 'Sedan', 'SUV');
create type public.booking_status as enum ('new', 'confirmed', 'assigned', 'completed', 'cancelled');
create type public.user_role      as enum ('admin', 'driver', 'customer');
create type public.driver_status  as enum ('pending', 'approved', 'suspended');

-- ---------- helpers --------------------------------------------------
create function public.slugify(txt text)
returns text language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(coalesce(txt, '')), '[^a-z0-9]+', '-', 'g'))
$$;

create function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- settings (everything that may change later) --------------
-- One row per setting. `is_public` rows are readable by the website.
create table public.settings (
  key         text primary key,
  value       jsonb not null,
  is_public   boolean not null default false,
  description text,
  updated_at  timestamptz not null default now()
);

insert into public.settings (key, value, is_public, description) values
  ('advance_percent',        '20',                                  true,  'Advance % charged via Razorpay link'),
  ('whatsapp_sender',        '"919009611602"',                      false, 'MSG91 integrated WhatsApp number'),
  ('whatsapp_namespace',     '"5f6d7b38_402c_4432_b048_6a2ad7492956"', false, 'MSG91 template namespace'),
  ('admin_whatsapp_numbers', '["918187962796","916263676216","918963952633"]', false, 'Numbers that receive admin alerts'),
  ('support_phone',          '"+919009611602"',                     true,  'Call / WhatsApp number shown on site'),
  ('support_email',          '"kitecabtaxiservice@gmail.com"',      true,  'Email shown on site and invoice'),
  ('business',               '{"name":"KiteCab","address":"","gstin":""}', true, 'Invoice header details'),
  ('booking_open',           'true',                                true,  'Master switch: accept online bookings');

-- ---------- locations & fares ----------------------------------------
create table public.locations (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  slug        text not null unique,
  state       text not null default 'CG',       -- CG, MH, BR, OD ...
  is_active   boolean not null default true,     -- admin can switch off temporarily
  is_featured boolean not null default false,    -- Raipur, Bilaspur ... (SEO city pages first)
  sort_order  int not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- One-way fares (pickup -> drop). Reverse direction is its own row.
create table public.routes (
  id               bigint generated always as identity primary key,
  from_location_id bigint not null references public.locations(id) on delete restrict,
  to_location_id   bigint not null references public.locations(id) on delete restrict,
  distance_km      int not null check (distance_km > 0),
  hatchback_price  int not null check (hatchback_price > 0),
  sedan_price      int not null check (sedan_price > 0),
  suv_price        int not null check (suv_price > 0),
  is_active        boolean not null default true,
  legacy_id        bigint,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (from_location_id, to_location_id),
  check (from_location_id <> to_location_id)
);
create index routes_to_idx on public.routes (to_location_id);

create table public.rental_packages (
  id              bigint generated always as identity primary key,
  hours           int not null check (hours > 0),
  km              int not null check (km > 0),
  hatchback_price int not null check (hatchback_price > 0),
  sedan_price     int not null check (sedan_price > 0),
  suv_price       int not null check (suv_price > 0),
  is_active       boolean not null default true,
  legacy_id       bigint,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (hours, km)
);

-- Round trip fare = per_km * approx_km + base   (per car type, per waiting slot)
create table public.round_trip_rates (
  id                 bigint generated always as identity primary key,
  waiting_slot       text not null unique,        -- '1-3 hours', '1 day' ...
  sort_order         int not null default 100,
  hatchback_per_km   int not null, sedan_per_km int not null, suv_per_km int not null,
  hatchback_base     int not null, sedan_base   int not null, suv_base   int not null,
  is_active          boolean not null default true,
  updated_at         timestamptz not null default now()
);

-- Current formula from the live site (cab-round-trip-dialog.component.ts)
insert into public.round_trip_rates
  (waiting_slot, sort_order, hatchback_per_km, sedan_per_km, suv_per_km, hatchback_base, sedan_base, suv_base) values
  ('1-3 hours', 1, 10, 11, 16, 1200, 1200, 1400),
  ('3-6 hours', 2, 10, 11, 16, 1200, 1200, 1400),
  ('6-9 hours', 3, 10, 11, 16, 1300, 1300, 1500),
  ('1 day',     4, 10, 11, 16, 1400, 1500, 1600),
  ('2 day',     5, 10, 11, 16, 2800, 3000, 3200),
  ('3 day',     6, 10, 11, 16, 4200, 4500, 4800);

-- ---------- people (future-proof: customer & driver logins) ----------
-- One row per Supabase Auth login.
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       public.user_role not null default 'customer',
  full_name  text,
  mobile     text,
  created_at timestamptz not null default now()
);

-- Everyone who books. auth_user_id is filled only when they create a login.
create table public.customers (
  id           bigint generated always as identity primary key,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  full_name    text not null,
  mobile       text not null unique,
  email        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.drivers (
  id               bigint generated always as identity primary key,
  auth_user_id     uuid unique references auth.users(id) on delete set null,
  full_name        text not null,
  mobile           text not null unique,
  alt_mobile       text,
  license_no       text,
  license_expiry   date,
  base_location_id bigint references public.locations(id),
  status           public.driver_status not null default 'pending',
  rating           numeric(2,1),
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table public.vehicles (
  id               bigint generated always as identity primary key,
  driver_id        bigint references public.drivers(id) on delete set null,
  registration_no  text not null unique,
  car_type         public.car_type not null,
  model            text,
  seats            int,
  insurance_expiry date,
  permit_expiry    date,
  puc_expiry       date,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Files live in a PRIVATE storage bucket; only the path is stored here.
create table public.driver_documents (
  id          bigint generated always as identity primary key,
  driver_id   bigint not null references public.drivers(id) on delete cascade,
  doc_type    text not null,           -- license, rc, insurance, id_proof, photo
  file_path   text not null,
  verified    boolean not null default false,
  uploaded_at timestamptz not null default now()
);

-- ---------- enquiries & bookings -------------------------------------
create table public.enquiries (
  id              bigint generated always as identity primary key,
  service_type    public.booking_type,
  pickup          text not null,
  drop_or_package text,
  mobile          text,                -- null when customer typed an invalid number
  created_at      timestamptz not null default now(),
  legacy_id       bigint
);
create index enquiries_created_idx on public.enquiries (created_at desc);

-- Booking IDs continue the legacy sequence (invoice no = id + 5125).
create table public.bookings (
  id                 bigint generated by default as identity (start with 999970) primary key,
  booking_type       public.booking_type not null,
  car_type           public.car_type not null,
  status             public.booking_status not null default 'new',

  -- trip (names are copied so history survives later renames/deletes)
  pickup_location    text not null,
  drop_location      text,
  route_id           bigint references public.routes(id) on delete set null,
  rental_package_id  bigint references public.rental_packages(id) on delete set null,
  rental_package     text,             -- e.g. '8 hours 80 km'
  waiting_time       text,             -- round trip slot
  approx_distance_km int,              -- round trip
  distance_km        int,

  -- money (always calculated on the server)
  fare               int not null check (fare >= 0),
  advance_percent    numeric(5,2),
  advance_amount     int,

  -- customer snapshot
  customer_id        bigint references public.customers(id) on delete set null,
  customer_name      text not null,
  mobile             text not null,
  email              text,
  passengers         int not null default 1 check (passengers > 0),
  pickup_address     text not null,
  pickup_date        date not null,
  pickup_time        text not null,

  -- operations
  driver_id          bigint references public.drivers(id) on delete set null,
  vehicle_id         bigint references public.vehicles(id) on delete set null,
  assigned_at        timestamptz,
  admin_notes        text,

  legacy_id          bigint,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index bookings_pickup_date_idx on public.bookings (pickup_date desc);
create index bookings_created_idx     on public.bookings (created_at desc);
create index bookings_mobile_idx      on public.bookings (mobile);
create index bookings_customer_idx    on public.bookings (customer_id);
create index bookings_driver_idx      on public.bookings (driver_id);

create table public.booking_status_history (
  id          bigint generated always as identity primary key,
  booking_id  bigint not null references public.bookings(id) on delete cascade,
  from_status public.booking_status,
  to_status   public.booking_status not null,
  changed_by  uuid references auth.users(id),
  note        text,
  created_at  timestamptz not null default now()
);

create function public.log_booking_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.booking_status_history (booking_id, from_status, to_status, changed_by)
    values (new.id, case when tg_op = 'UPDATE' then old.status end, new.status, auth.uid());
  end if;
  return new;
end $$;

create trigger bookings_status_log
  after insert or update of status on public.bookings
  for each row execute function public.log_booking_status();

-- ---------- payments (NEW table; the live `payments` table is only read) --
create table public.booking_payments (
  id                       bigint generated always as identity primary key,
  booking_id               bigint not null,
  customer_name            text not null,
  mobile                   text not null,
  booking_amount           int not null,
  advance_amount           int not null,
  payment_type             text not null default 'ADVANCE',
  status                   text not null default 'PENDING'
                             check (status in ('PENDING', 'PAID', 'EXPIRED', 'CANCELLED', 'FAILED')),
  payment_link             text,
  razorpay_payment_link_id text not null unique,
  razorpay_payment_id      text unique,
  reference_id             text,
  attempt                  int not null default 1,   -- admin "new link" uses attempt + 1
  amount_paid              int,
  paid_at                  timestamptz,
  webhook_response         jsonb,
  legacy_id                bigint,                   -- id in the old `payments` table
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index booking_payments_booking_idx on public.booking_payments (booking_id);
create index booking_payments_created_idx on public.booking_payments (created_at desc);

-- ---------- updated_at triggers --------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locations','routes','rental_packages','round_trip_rates',
                           'customers','drivers','vehicles','bookings','settings','booking_payments']
  loop
    execute format('create trigger %I_touch before update on public.%I
                    for each row execute function public.touch_updated_at()', t, t);
  end loop;
end $$;

-- ---------- public read views (what the website may see) -------------
create view public.route_fares with (security_invoker = true) as
select r.id,
       f.name as pickup, f.slug as pickup_slug,
       t.name as drop,   t.slug as drop_slug,
       f.slug || '-to-' || t.slug as slug,
       r.distance_km, r.hatchback_price, r.sedan_price, r.suv_price
from public.routes r
join public.locations f on f.id = r.from_location_id and f.is_active
join public.locations t on t.id = r.to_location_id   and t.is_active
where r.is_active;

commit;

-- ##################### 002_rls.sql #####################
-- =====================================================================
begin;
-- KiteCab v2 — Row Level Security
-- Rule of thumb:
--   * website visitors (anon)  -> read active fares + public settings only
--   * all writes from the site -> go through the backend (service key)
--   * admin                    -> full access via Supabase Auth login
--   * driver / customer        -> only their own rows (future logins)
-- The live `kitecab` and `payments` tables are NOT touched here.
-- =====================================================================

create function public.current_role_is(r public.user_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = r)
$$;

create function public.is_admin()
returns boolean language sql stable as $$ select public.current_role_is('admin') $$;

-- enable RLS everywhere (no policy = no access)
alter table public.settings               enable row level security;
alter table public.locations              enable row level security;
alter table public.routes                 enable row level security;
alter table public.rental_packages        enable row level security;
alter table public.round_trip_rates       enable row level security;
alter table public.profiles               enable row level security;
alter table public.customers              enable row level security;
alter table public.drivers                enable row level security;
alter table public.vehicles               enable row level security;
alter table public.driver_documents       enable row level security;
alter table public.enquiries              enable row level security;
alter table public.bookings               enable row level security;
alter table public.booking_status_history enable row level security;
alter table public.booking_payments       enable row level security;

-- ---------- public catalogue -----------------------------------------
create policy "public read active locations" on public.locations
  for select using (is_active or public.is_admin());
create policy "public read active routes" on public.routes
  for select using (is_active or public.is_admin());
create policy "public read active rentals" on public.rental_packages
  for select using (is_active or public.is_admin());
create policy "public read active round trip" on public.round_trip_rates
  for select using (is_active or public.is_admin());
create policy "public read public settings" on public.settings
  for select using (is_public or public.is_admin());

-- ---------- admin: full access to everything -------------------------
do $$
declare t text;
begin
  foreach t in array array['settings','locations','routes','rental_packages','round_trip_rates',
                           'profiles','customers','drivers','vehicles','driver_documents',
                           'enquiries','bookings','booking_status_history','booking_payments']
  loop
    execute format('create policy "admin all %1$s" on public.%1$I
                    for all using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- ---------- own rows (future customer / driver logins) ----------------
create policy "read own profile" on public.profiles
  for select using (id = auth.uid());

create policy "customer reads self" on public.customers
  for select using (auth_user_id = auth.uid());
create policy "customer reads own bookings" on public.bookings
  for select using (customer_id in (select id from public.customers where auth_user_id = auth.uid()));

create policy "driver reads self" on public.drivers
  for select using (auth_user_id = auth.uid());
create policy "driver reads assigned bookings" on public.bookings
  for select using (driver_id in (select id from public.drivers where auth_user_id = auth.uid()));
create policy "driver reads own vehicles" on public.vehicles
  for select using (driver_id in (select id from public.drivers where auth_user_id = auth.uid()));
create policy "driver reads own documents" on public.driver_documents
  for select using (driver_id in (select id from public.drivers where auth_user_id = auth.uid()));

-- ---------- table grants (RLS still applies on top) -------------------
-- Only NEW tables are touched; legacy `kitecab` / `payments` grants stay as-is.
revoke all on public.settings, public.locations, public.routes, public.rental_packages,
              public.round_trip_rates, public.route_fares, public.profiles, public.customers,
              public.drivers, public.vehicles, public.driver_documents, public.enquiries,
              public.bookings, public.booking_status_history,
              public.booking_payments
  from anon, authenticated;
grant select on public.settings, public.locations, public.routes, public.rental_packages,
                public.round_trip_rates, public.route_fares to anon, authenticated;
grant insert, update, delete on public.settings, public.locations, public.routes,
                public.rental_packages, public.round_trip_rates to authenticated;
grant select, insert, update, delete on public.profiles, public.customers, public.drivers,
                public.vehicles, public.driver_documents, public.enquiries, public.bookings,
                public.booking_status_history, public.booking_payments to authenticated;

-- ---------- admin bootstrap -------------------------------------------
-- 1. Supabase dashboard -> Authentication -> Users -> Add user
--    (kitecabtaxiservice@gmail.com, strong password, auto-confirm)
-- 2. Then run:
--    insert into public.profiles (id, role, full_name)
--    select id, 'admin', 'KiteCab Admin' from auth.users
--    where email = 'kitecabtaxiservice@gmail.com'
--    on conflict (id) do update set role = 'admin';

commit;

-- ##################### 003_migrate_legacy_data.sql #####################
-- =====================================================================
-- KiteCab v2 — copy legacy JSON data (table `kitecab`) into new tables
--
-- * Re-runnable until launch: it EMPTIES the new tables first, then
--   rebuilds them from the legacy rows. Run it one final time at cutover.
-- * Only READS the live `kitecab` and `payments` tables — never changes them.
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
truncate public.booking_payments, public.booking_status_history, public.bookings, public.customers,
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

-- ---------- payments (copied from the live `payments` table) ---------
insert into public.booking_payments (booking_id, customer_name, mobile, booking_amount, advance_amount,
       payment_type, status, payment_link, razorpay_payment_link_id, razorpay_payment_id, reference_id,
       paid_at, webhook_response, legacy_id, created_at, updated_at)
select p.booking_id,
       coalesce(nullif(trim(p.customer_name), ''), '-'),
       coalesce(trim(p.mobile), ''),
       round(coalesce(p.booking_amount, 0))::int,
       round(coalesce(p.advance_amount, 0))::int,
       coalesce(p.payment_type, 'ADVANCE'),
       case when p.status in ('PENDING', 'PAID', 'EXPIRED', 'CANCELLED', 'FAILED') then p.status else 'PENDING' end,
       p.payment_link,
       p.razorpay_payment_link_id,
       nullif(p.razorpay_payment_id, ''),
       p.reference_id,
       p.paid_at at time zone 'UTC',          -- live column is 'timestamp without time zone' (UTC)
       p.webhook_response,
       p.id,
       p.created_at,
       coalesce(p.updated_at, p.created_at)
from public.payments p
where p.booking_id is not null and p.razorpay_payment_link_id is not null
order by p.id
on conflict (razorpay_payment_link_id) do nothing;

alter table public.bookings enable trigger bookings_status_log;

-- remove the temporary helpers
drop function pg_temp.to_int(text), pg_temp.place(text), pg_temp.car(text), pg_temp.btype(text),
              pg_temp.pickup_date(text), pg_temp.mobile(text), pg_temp.enquiry_ts(text, text),
              pg_temp.legacy(text);

commit;

-- ##################### 004_api_support.sql #####################
-- =====================================================================
-- KiteCab v2 — columns used by the Vercel API
-- ip_hash: salted SHA-256 of the client IP (raw IPs are never stored),
--          used only for spam limits.
-- =====================================================================
begin;
alter table public.enquiries add column if not exists ip_hash text;
alter table public.bookings  add column if not exists ip_hash text;

create index if not exists enquiries_ip_recent_idx     on public.enquiries (ip_hash, created_at desc);
create index if not exists enquiries_mobile_recent_idx on public.enquiries (mobile, created_at desc);
create index if not exists bookings_ip_recent_idx      on public.bookings  (ip_hash, created_at desc);

commit;

-- ---------- summary (this is what the SQL Editor shows) ---------------------------------------------------
select 'locations' as tbl, count(*) from public.locations
union all select 'routes', count(*) from public.routes
union all select 'rental_packages', count(*) from public.rental_packages
union all select 'bookings', count(*) from public.bookings
union all select 'customers', count(*) from public.customers
union all select 'enquiries', count(*) from public.enquiries
union all select 'enquiries with invalid mobile (NULL)', count(*) from public.enquiries where mobile is null
union all select 'payments', count(*) from public.booking_payments
union all select 'payments PAID', count(*) from public.booking_payments where status = 'PAID';
