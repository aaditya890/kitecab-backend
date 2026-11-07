-- =====================================================================
-- KiteCab v2 — richer admin dashboard numbers in ONE call.
-- New function only; nothing existing changes. Admin only (is_admin()).
-- =====================================================================
begin;

create function public.admin_stats(p_days int default 30)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare
  today   date := (now() at time zone 'Asia/Kolkata')::date;
  since   date := today - (least(greatest(p_days, 7), 365) - 1);
  m_start date := date_trunc('month', today)::date;
  pm_start date := (date_trunc('month', today) - interval '1 month')::date;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;

  return jsonb_build_object(
    -- bookings and enquiries per day (India time), zero-filled
    'daily', (
      select jsonb_agg(jsonb_build_object('day', d::date, 'bookings', coalesce(b.n, 0), 'enquiries', coalesce(e.n, 0)) order by d)
      from generate_series(since, today, interval '1 day') d
      left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n
                   from bookings where created_at >= since::timestamp at time zone 'Asia/Kolkata' group by 1) b on b.day = d::date
      left join (select (created_at at time zone 'Asia/Kolkata')::date as day, count(*) n
                   from enquiries where created_at >= since::timestamp at time zone 'Asia/Kolkata' group by 1) e on e.day = d::date
    ),
    -- this month vs last month (same number of days, so the comparison is fair)
    'month', (
      select jsonb_build_object(
        'bookings',      count(*) filter (where c >= m_start),
        'fare',          coalesce(sum(fare) filter (where c >= m_start and status <> 'cancelled'), 0),
        'prev_bookings', count(*) filter (where c >= pm_start and c < pm_start + (today - m_start + 1)),
        'prev_fare',     coalesce(sum(fare) filter (where c >= pm_start and c < pm_start + (today - m_start + 1) and status <> 'cancelled'), 0)
      )
      from (select (created_at at time zone 'Asia/Kolkata')::date c, fare, status from bookings
             where created_at >= pm_start::timestamp at time zone 'Asia/Kolkata') x
    ),
    'by_type', (
      select coalesce(jsonb_object_agg(booking_type, n), '{}') from (
        select booking_type, count(*) n from bookings
        where created_at >= since::timestamp at time zone 'Asia/Kolkata' group by 1) t
    ),
    'by_status', (
      select coalesce(jsonb_object_agg(status, n), '{}') from (
        select status, count(*) n from bookings
        where created_at >= since::timestamp at time zone 'Asia/Kolkata' group by 1) t
    ),
    'top_routes', (
      select coalesce(jsonb_agg(r), '[]') from (
        select pickup_location as pickup, coalesce(drop_location, rental_package, '-') as drop, count(*) as bookings,
               coalesce(sum(fare) filter (where status <> 'cancelled'), 0) as fare
        from bookings where created_at >= since::timestamp at time zone 'Asia/Kolkata'
        group by 1, 2 order by 3 desc, 4 desc limit 8) r
    ),
    'advance', (
      select jsonb_build_object(
        'paid',    coalesce(sum(coalesce(amount_paid, advance_amount)) filter (where status = 'PAID'), 0),
        'paid_n',  count(*) filter (where status = 'PAID'),
        'pending_n', count(*) filter (where status = 'PENDING'))
      from booking_payments where created_at >= since::timestamp at time zone 'Asia/Kolkata'
    ),
    -- future trips that still need a driver (next 7 days)
    'needs_driver', (
      select count(*) from bookings
      where pickup_date between today and today + 7 and driver_id is null and status not in ('cancelled', 'completed')
    )
  );
end $$;

revoke execute on function public.admin_stats(int) from anon, public;
grant execute on function public.admin_stats(int) to authenticated;

commit;
