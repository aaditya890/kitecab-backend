-- =====================================================================
-- KiteCab v2 — save customer + booking in ONE database call (faster booking).
-- Called only by the backend (secret key); not callable from the browser.
-- =====================================================================
begin;

create function public.create_booking(p_customer jsonb, p_booking jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cid bigint;
  r   public.bookings;
  saved public.bookings;
begin
  insert into public.customers (full_name, mobile, email)
  values (p_customer->>'full_name', p_customer->>'mobile', nullif(p_customer->>'email', ''))
  on conflict (mobile) do update
    set full_name = excluded.full_name,
        email     = coalesce(excluded.email, public.customers.email)
  returning id into cid;

  r := jsonb_populate_record(null::public.bookings, p_booking);
  insert into public.bookings (
    booking_type, car_type, pickup_location, drop_location, route_id, rental_package_id, rental_package,
    waiting_time, approx_distance_km, distance_km, fare, advance_percent, advance_amount,
    customer_id, customer_name, mobile, email, passengers, pickup_address, pickup_date, pickup_time, ip_hash
  ) values (
    r.booking_type, r.car_type, r.pickup_location, r.drop_location, r.route_id, r.rental_package_id, r.rental_package,
    r.waiting_time, r.approx_distance_km, r.distance_km, r.fare, r.advance_percent, r.advance_amount,
    cid, r.customer_name, r.mobile, r.email, r.passengers, r.pickup_address, r.pickup_date, r.pickup_time, r.ip_hash
  )
  returning * into saved;

  return to_jsonb(saved);
end $$;

revoke execute on function public.create_booking(jsonb, jsonb) from public, anon, authenticated;

commit;
