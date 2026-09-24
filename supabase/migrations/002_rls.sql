-- =====================================================================
-- KiteCab v2 — Row Level Security
-- Rule of thumb:
--   * website visitors (anon)  -> read active fares + public settings only
--   * all writes from the site -> go through the backend (service key)
--   * admin                    -> full access via Supabase Auth login
--   * driver / customer        -> only their own rows (future logins)
-- The legacy `kitecab` and `payments` tables are locked in 004_cutover.sql,
-- NOT here, so the live site keeps working until the switch.
-- =====================================================================

create or replace function public.current_role_is(r public.user_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = r)
$$;

create or replace function public.is_admin()
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
                           'enquiries','bookings','booking_status_history']
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
              public.bookings, public.booking_status_history
  from anon, authenticated;
grant select on public.settings, public.locations, public.routes, public.rental_packages,
                public.round_trip_rates, public.route_fares to anon, authenticated;
grant insert, update, delete on public.settings, public.locations, public.routes,
                public.rental_packages, public.round_trip_rates to authenticated;
grant select, insert, update, delete on public.profiles, public.customers, public.drivers,
                public.vehicles, public.driver_documents, public.enquiries, public.bookings,
                public.booking_status_history to authenticated;

-- ---------- admin bootstrap -------------------------------------------
-- 1. Supabase dashboard -> Authentication -> Users -> Add user
--    (kitecabtaxiservice@gmail.com, strong password, auto-confirm)
-- 2. Then run:
--    insert into public.profiles (id, role, full_name)
--    select id, 'admin', 'KiteCab Admin' from auth.users
--    where email = 'kitecabtaxiservice@gmail.com'
--    on conflict (id) do update set role = 'admin';
