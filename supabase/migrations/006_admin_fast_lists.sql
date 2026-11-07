-- =====================================================================
-- KiteCab v2 — admin panel speed: search indexes, list views, dashboard RPC
-- New objects only; live `kitecab` / `payments` untouched. NOT YET TESTED.
-- =====================================================================
begin;

create extension if not exists pg_trgm;

-- fast "contains" search on names / places, prefix search on mobiles
create index if not exists bookings_name_trgm      on public.bookings  using gin (customer_name gin_trgm_ops);
create index if not exists bookings_mobile_prefix  on public.bookings  (mobile text_pattern_ops);
create index if not exists bookings_status_date    on public.bookings  (status, pickup_date desc);
create index if not exists customers_name_trgm     on public.customers using gin (full_name gin_trgm_ops);
create index if not exists customers_mobile_prefix on public.customers (mobile text_pattern_ops);
create index if not exists enquiries_pickup_trgm   on public.enquiries using gin (pickup gin_trgm_ops);
create index if not exists booking_payments_status on public.booking_payments (status, created_at desc);

-- Booking list row with latest advance status. security_invoker = RLS applies (admin only).
-- Scalar subqueries run only for the 25 rows of the page.
create view public.admin_bookings with (security_invoker = true) as
select b.id, b.booking_type, b.car_type, b.status, b.pickup_location, b.drop_location, b.rental_package,
       b.pickup_date, b.pickup_time, b.fare, b.advance_amount, b.customer_name, b.mobile,
       b.driver_id, b.created_at,
       (select d.full_name from public.drivers d where d.id = b.driver_id) as driver_name,
       (select bp.status from public.booking_payments bp
         where bp.booking_id = b.id order by bp.created_at desc limit 1)  as advance_status
from public.bookings b;

create view public.admin_customers with (security_invoker = true) as
select c.id, c.full_name, c.mobile, c.email, c.created_at,
       (select count(*) from public.bookings b where b.customer_id = c.id)            as bookings,
       (select coalesce(sum(b.fare), 0) from public.bookings b
         where b.customer_id = c.id and b.status <> 'cancelled')                       as total_fare,
       (select max(b.pickup_date) from public.bookings b where b.customer_id = c.id)  as last_trip
from public.customers c;

create view public.admin_routes with (security_invoker = true) as
select r.id, r.from_location_id, r.to_location_id, f.name as pickup, t.name as drop,
       r.distance_km, r.hatchback_price, r.sedan_price, r.suv_price, r.is_active
from public.routes r
join public.locations f on f.id = r.from_location_id
join public.locations t on t.id = r.to_location_id;

-- Dashboard numbers in ONE call.
create function public.admin_dashboard()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'bookings_today',   (select count(*) from bookings where (created_at at time zone 'Asia/Kolkata')::date = today),
    'bookings_yesterday', (select count(*) from bookings where (created_at at time zone 'Asia/Kolkata')::date = today - 1),
    'pickups_today',    (select count(*) from bookings where pickup_date = today and status <> 'cancelled'),
    'pickups_no_driver',(select count(*) from bookings where pickup_date = today and status <> 'cancelled' and driver_id is null),
    'advance_week',     (select coalesce(sum(amount_paid), 0) from booking_payments
                          where status = 'PAID' and paid_at >= now() - interval '7 days'),
    'enquiries_today',  (select count(*) from enquiries where (created_at at time zone 'Asia/Kolkata')::date = today)
  );
end $$;

revoke all on public.admin_bookings, public.admin_customers, public.admin_routes from anon;
grant select on public.admin_bookings, public.admin_customers, public.admin_routes to authenticated;
revoke execute on function public.admin_dashboard() from anon, public;
grant execute on function public.admin_dashboard() to authenticated;

commit;
