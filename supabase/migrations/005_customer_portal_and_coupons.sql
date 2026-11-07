-- =====================================================================
-- KiteCab v2 — customer login (my bookings + driver details) and coupons
-- New objects only; the live `kitecab` / `payments` tables are untouched.
-- =====================================================================
begin;

-- bookings remember the price before and after a coupon
alter table public.bookings
  add column fare_before_discount int,
  add column discount_amount int not null default 0 check (discount_amount >= 0),
  add column coupon_code text;

-- ---------- customer login ------------------------------------------
-- When someone signs up (phone OTP or email) a `profiles` row is created
-- and, if their phone matches a customer, that customer (with all past
-- bookings) is linked to the login automatically.
create function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare mobile10 text := right(regexp_replace(coalesce(new.phone, ''), '\D', '', 'g'), 10);
begin
  insert into public.profiles (id, role, mobile)
  values (new.id, 'customer', nullif(mobile10, ''))
  on conflict (id) do nothing;

  if length(mobile10) = 10 then
    update public.customers set auth_user_id = new.id
    where mobile = mobile10 and auth_user_id is null;
  end if;
  return new;
end $$;

create trigger kitecab_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- What a logged-in customer sees: only their own bookings, with the driver
-- and car once one is assigned. Runs with the view owner's rights, so the
-- `where` clause on auth.uid() is the security boundary — keep it.
create view public.my_bookings as
select b.id, b.booking_type, b.car_type, b.status,
       b.pickup_location, b.drop_location, b.rental_package, b.waiting_time,
       b.pickup_address, b.pickup_date, b.pickup_time, b.passengers,
       b.fare, b.fare_before_discount, b.discount_amount, b.coupon_code,
       b.advance_amount,
       (select bp.status from public.booking_payments bp
         where bp.booking_id = b.id order by bp.created_at desc limit 1)       as advance_status,
       (select bp.payment_link from public.booking_payments bp
         where bp.booking_id = b.id and bp.status = 'PENDING'
         order by bp.created_at desc limit 1)                                  as pay_link,
       case when b.status in ('assigned', 'confirmed', 'completed') then d.full_name end       as driver_name,
       case when b.status in ('assigned', 'confirmed') then d.mobile end                       as driver_mobile,
       case when b.status in ('assigned', 'confirmed', 'completed') then v.registration_no end as car_number,
       case when b.status in ('assigned', 'confirmed', 'completed') then v.model end           as car_model,
       b.created_at
from public.bookings b
join public.customers c on c.id = b.customer_id
left join public.drivers d on d.id = b.driver_id
left join public.vehicles v on v.id = b.vehicle_id
where c.auth_user_id = auth.uid();

-- ---------- coupons (ready for later) ----------------------------------
create type public.discount_type as enum ('percent', 'flat');

create table public.coupons (
  id                 bigint generated always as identity primary key,
  code               text not null unique check (code = upper(code) and code ~ '^[A-Z0-9]{3,20}$'),
  description        text,
  discount_type      public.discount_type not null,
  discount_value     int not null check (discount_value > 0),
  max_discount       int check (max_discount > 0),          -- cap for percent coupons
  min_fare           int not null default 0,
  booking_types      public.booking_type[],                  -- null = all trip types
  car_types          public.car_type[],                      -- null = all cars
  pickup_location_ids bigint[],                              -- null = every city
  first_booking_only boolean not null default false,
  usage_limit        int check (usage_limit > 0),            -- null = unlimited
  per_customer_limit int not null default 1 check (per_customer_limit > 0),
  valid_from         timestamptz,
  valid_until        timestamptz,
  is_active          boolean not null default true,
  is_public          boolean not null default false,         -- show on website offers
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (discount_type <> 'percent' or discount_value <= 100),
  check (valid_until is null or valid_from is null or valid_until > valid_from)
);

create table public.coupon_redemptions (
  id              bigint generated always as identity primary key,
  coupon_id       bigint not null references public.coupons(id) on delete restrict,
  booking_id      bigint not null unique references public.bookings(id) on delete cascade,
  customer_id     bigint references public.customers(id) on delete set null,
  mobile          text not null,
  discount_amount int not null check (discount_amount > 0),
  created_at      timestamptz not null default now()
);
create index coupon_redemptions_coupon_idx on public.coupon_redemptions (coupon_id);
create index coupon_redemptions_mobile_idx on public.coupon_redemptions (mobile);

create trigger coupons_touch before update on public.coupons
  for each row execute function public.touch_updated_at();

-- ---------- security --------------------------------------------------
alter table public.coupons            enable row level security;
alter table public.coupon_redemptions enable row level security;

create policy "admin all coupons" on public.coupons
  for all using (public.is_admin()) with check (public.is_admin());
create policy "public read live public coupons" on public.coupons
  for select using (is_active and is_public
                    and (valid_from is null or valid_from <= now())
                    and (valid_until is null or valid_until > now()));
create policy "admin all coupon_redemptions" on public.coupon_redemptions
  for all using (public.is_admin()) with check (public.is_admin());

revoke all on public.coupons, public.coupon_redemptions, public.my_bookings from anon, authenticated;
grant select on public.coupons to anon, authenticated;
grant insert, update, delete on public.coupons to authenticated;
grant select, insert, update, delete on public.coupon_redemptions to authenticated;
grant select on public.my_bookings to authenticated;

commit;
