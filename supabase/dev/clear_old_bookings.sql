-- =====================================================================
-- DEV project only. Removes the copied OLD bookings, enquiries, customers
-- and payments so the new flow starts clean. Locations, routes, rental
-- packages, round-trip rates, drivers, settings and logins are kept.
-- Booking numbers keep counting up (no restart), so invoice numbers never repeat.
-- The backup CSVs and the live project are not affected.
-- =====================================================================
begin;
truncate public.coupon_redemptions, public.enquiry_followups, public.booking_status_history,
         public.booking_payments, public.bookings, public.enquiries, public.customers;
delete from public.activity_log where entity in ('booking', 'enquiry');
commit;

select 'bookings' t, count(*) from public.bookings union all
select 'enquiries', count(*) from public.enquiries union all
select 'customers', count(*) from public.customers union all
select 'routes (kept)', count(*) from public.routes union all
select 'locations (kept)', count(*) from public.locations;
