-- =====================================================================
-- KiteCab v2 — core schema
-- Run in Supabase SQL editor (or `supabase db push`).
-- Creates NEW tables alongside the legacy `kitecab` table, so the live
-- site keeps working until cutover. Safe to run once on a fresh project.
-- =====================================================================

-- ---------- enums ----------------------------------------------------
create type public.booking_type   as enum ('oneway', 'round-trip', 'local-rental');
create type public.car_type       as enum ('Hatchback', 'Sedan', 'SUV');
create type public.booking_status as enum ('new', 'confirmed', 'assigned', 'completed', 'cancelled');
create type public.user_role      as enum ('admin', 'driver', 'customer');
create type public.driver_status  as enum ('pending', 'approved', 'suspended');

-- ---------- helpers --------------------------------------------------
create or replace function public.slugify(txt text)
returns text language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(coalesce(txt, '')), '[^a-z0-9]+', '-', 'g'))
$$;

create or replace function public.touch_updated_at()
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

create or replace function public.log_booking_status()
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

-- ---------- payments (existing table: extend, don't recreate) --------
-- The live site already writes here; only additive changes now.
alter table public.payments
  add column if not exists amount_paid int,
  add column if not exists failure_reason text;
create unique index if not exists payments_link_id_uidx on public.payments (razorpay_payment_link_id);
create unique index if not exists payments_payment_id_uidx on public.payments (razorpay_payment_id)
  where razorpay_payment_id is not null;
create index if not exists payments_booking_idx on public.payments (booking_id);

-- ---------- updated_at triggers --------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locations','routes','rental_packages','round_trip_rates',
                           'customers','drivers','vehicles','bookings','settings']
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
