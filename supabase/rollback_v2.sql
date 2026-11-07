-- =====================================================================
-- UNDO setup_v2.sql — removes every NEW object it created.
-- Does NOT touch the live `kitecab` / `payments` tables.
-- (The admin login in Authentication -> Users is left; delete it there if wanted.)
-- =====================================================================
begin;

drop view if exists public.route_fares, public.my_bookings, public.admin_bookings, public.admin_customers, public.admin_routes;
drop trigger if exists kitecab_on_auth_user_created on auth.users;
drop function if exists public.admin_dashboard(), public.handle_new_auth_user();

drop table if exists
  public.coupon_redemptions, public.coupons, public.booking_payments, public.booking_status_history, public.bookings, public.enquiries,
  public.driver_documents, public.vehicles, public.drivers, public.customers, public.profiles,
  public.round_trip_rates, public.rental_packages, public.routes, public.locations, public.settings
  cascade;

drop function if exists
  public.log_booking_status(), public.is_admin(), public.current_role_is(public.user_role),
  public.touch_updated_at(), public.slugify(text);

drop type if exists
  public.discount_type, public.driver_status, public.user_role, public.booking_status, public.car_type, public.booking_type;

commit;

select 'v2 objects removed' as result;
