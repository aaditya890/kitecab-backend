-- =====================================================================
-- KiteCab v2 — office workflow: staff logins, enquiry follow-ups,
-- richer bookings and an automatic activity log (who did what, when).
-- New objects / new columns only. Live `kitecab` / `payments` untouched.
-- =====================================================================

-- Enum values must be committed before use, so this runs outside the transaction.
alter type public.user_role add value if not exists 'staff';

begin;

-- ---------- who is office staff --------------------------------------
-- Staff = admin or staff. Text compare, so it works in the same script as the new enum value.
create function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text in ('admin', 'staff'))
$$;

create function public.staff_name(uid uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(p.full_name, ''), u.email, 'System')
  from auth.users u left join public.profiles p on p.id = u.id where u.id = uid
$$;

-- ---------- enquiries become leads ------------------------------------
create type public.lead_status as enum ('new', 'contacted', 'follow_up', 'converted', 'not_interested', 'invalid');

alter table public.enquiries
  add column status            public.lead_status not null default 'new',
  add column customer_name     text,
  add column quoted_fare       int,
  add column assigned_to       uuid references auth.users(id) on delete set null,
  add column next_follow_up_at timestamptz,
  add column last_contacted_at timestamptz,
  add column attempts          int not null default 0,
  add column note              text,
  add column lost_reason       text,
  add column booking_id        bigint references public.bookings(id) on delete set null,
  add column source            text not null default 'website',
  add column updated_at        timestamptz not null default now();

create index enquiries_status_idx   on public.enquiries (status, created_at desc);
create index enquiries_followup_idx on public.enquiries (next_follow_up_at) where status in ('new', 'contacted', 'follow_up');
create index enquiries_mobile_idx   on public.enquiries (mobile text_pattern_ops);

create trigger enquiries_touch before update on public.enquiries
  for each row execute function public.touch_updated_at();

-- One row per call / WhatsApp / note on a lead.
create table public.enquiry_followups (
  id           bigint generated always as identity primary key,
  enquiry_id   bigint not null references public.enquiries(id) on delete cascade,
  staff_id     uuid default auth.uid() references auth.users(id) on delete set null,
  channel      text not null default 'call' check (channel in ('call', 'whatsapp', 'note')),
  outcome      text not null check (outcome in ('no_answer', 'busy', 'interested', 'call_back', 'booked', 'not_interested', 'wrong_number', 'note')),
  note         text,
  next_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index enquiry_followups_enquiry_idx on public.enquiry_followups (enquiry_id, created_at desc);
create index enquiry_followups_staff_idx   on public.enquiry_followups (staff_id, created_at desc);

-- A follow-up updates its lead: status, attempts, next date, last contacted.
create function public.apply_followup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enquiries e set
    attempts          = e.attempts + case when new.channel = 'note' then 0 else 1 end,
    last_contacted_at = case when new.channel = 'note' then e.last_contacted_at else new.created_at end,
    next_follow_up_at = case when new.outcome in ('booked', 'not_interested', 'wrong_number') then null
                             else coalesce(new.next_at, e.next_follow_up_at) end,
    assigned_to       = coalesce(e.assigned_to, new.staff_id),
    status = (case new.outcome
               when 'booked'         then 'converted'
               when 'not_interested' then 'not_interested'
               when 'wrong_number'   then 'invalid'
               when 'note'           then e.status::text
               else case when new.next_at is not null or new.outcome in ('interested', 'call_back')
                         then 'follow_up' else 'contacted' end
             end)::public.lead_status,
    lost_reason = case when new.outcome in ('not_interested', 'wrong_number') then coalesce(new.note, e.lost_reason) else e.lost_reason end
  where e.id = new.enquiry_id and (e.status <> 'converted' or new.outcome = 'note');
  return new;
end $$;

create trigger enquiry_followups_apply after insert on public.enquiry_followups
  for each row execute function public.apply_followup();

-- ---------- bookings: office fields -----------------------------------
alter table public.bookings
  add column source            text not null default 'website' check (source in ('website', 'phone', 'whatsapp', 'walk_in', 'repeat', 'other')),
  add column created_by        uuid references auth.users(id) on delete set null,
  add column handled_by        uuid references auth.users(id) on delete set null,
  add column enquiry_id        bigint references public.enquiries(id) on delete set null,
  add column cancel_reason     text,
  add column cancelled_at      timestamptz,
  add column completed_at      timestamptz,
  add column balance_collected int check (balance_collected >= 0),
  add column balance_mode      text check (balance_mode in ('cash', 'upi', 'card', 'bank')),
  add column extra_charges     int not null default 0 check (extra_charges >= 0),
  add column extra_note        text,
  add column customer_rating   int check (customer_rating between 1 and 5),
  add column feedback          text;

create index bookings_source_idx  on public.bookings (source, created_at desc);
create index bookings_handled_idx on public.bookings (handled_by);

-- A new booking from the same mobile closes that person's open leads (last 7 days).
create function public.link_booking_to_lead()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.enquiries set status = 'converted', booking_id = new.id, next_follow_up_at = null
  where mobile = new.mobile and status in ('new', 'contacted', 'follow_up')
    and created_at > now() - interval '7 days';
  return new;
end $$;

create trigger bookings_link_lead after insert on public.bookings
  for each row execute function public.link_booking_to_lead();

-- ---------- activity log (automatic) ----------------------------------
create table public.activity_log (
  id          bigint generated always as identity primary key,
  actor_id    uuid default auth.uid(),
  entity      text not null,            -- booking, enquiry, route, setting ...
  entity_id   text not null,
  action      text not null,            -- created, status, driver, fare, follow_up ...
  detail      text,
  created_at  timestamptz not null default now()
);
create index activity_log_entity_idx on public.activity_log (entity, entity_id, created_at desc);
create index activity_log_actor_idx  on public.activity_log (actor_id, created_at desc);
create index activity_log_time_idx   on public.activity_log (created_at desc);

create function public.log_booking_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare who uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    insert into activity_log (actor_id, entity, entity_id, action, detail)
    values (who, 'booking', new.id, 'created', new.source || ' · ' || new.pickup_location || ' → ' || coalesce(new.drop_location, new.rental_package, '') || ' · ₹' || new.fare);
    return new;
  end if;
  if new.status is distinct from old.status then
    insert into activity_log (actor_id, entity, entity_id, action, detail)
    values (who, 'booking', new.id, 'status', old.status || ' → ' || new.status || coalesce(' · ' || new.cancel_reason, ''));
  end if;
  if new.driver_id is distinct from old.driver_id or new.vehicle_id is distinct from old.vehicle_id then
    insert into activity_log (actor_id, entity, entity_id, action, detail)
    values (who, 'booking', new.id, 'driver',
            coalesce((select full_name from drivers where id = new.driver_id), 'removed') ||
            coalesce(' · ' || (select registration_no from vehicles where id = new.vehicle_id), ''));
  end if;
  if new.fare is distinct from old.fare then
    insert into activity_log (actor_id, entity, entity_id, action, detail)
    values (who, 'booking', new.id, 'fare', '₹' || old.fare || ' → ₹' || new.fare);
  end if;
  if new.pickup_date is distinct from old.pickup_date or new.pickup_time is distinct from old.pickup_time then
    insert into activity_log (actor_id, entity, entity_id, action, detail)
    values (who, 'booking', new.id, 'pickup', new.pickup_date || ' ' || new.pickup_time);
  end if;
  if new.balance_collected is distinct from old.balance_collected and new.balance_collected is not null then
    insert into activity_log (actor_id, entity, entity_id, action, detail)
    values (who, 'booking', new.id, 'collected', '₹' || new.balance_collected || coalesce(' by ' || new.balance_mode, ''));
  end if;
  return new;
end $$;

create trigger bookings_activity after insert or update on public.bookings
  for each row execute function public.log_booking_activity();

create function public.log_followup_activity()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log (actor_id, entity, entity_id, action, detail)
  values (new.staff_id, 'enquiry', new.enquiry_id, 'follow_up', new.channel || ' · ' || new.outcome || coalesce(' · ' || new.note, ''));
  return new;
end $$;

create trigger enquiry_followups_activity after insert on public.enquiry_followups
  for each row execute function public.log_followup_activity();

-- ---------- list views for the office --------------------------------
create view public.admin_enquiries with (security_invoker = true) as
select e.*,
       public.staff_name(e.assigned_to) as assigned_name,
       (select count(*) from public.bookings b where b.mobile = e.mobile) as past_bookings
from public.enquiries e;

create view public.admin_activity with (security_invoker = true) as
select a.*, public.staff_name(a.actor_id) as actor_name from public.activity_log a;

-- Staff list (names + role). Runs with owner rights to read auth.users, so the
-- is_staff() filter below is what keeps it private — keep it.
create view public.admin_staff as
select p.id, p.role::text as role, p.full_name, p.mobile, u.email, u.last_sign_in_at, p.created_at
from public.profiles p join auth.users u on u.id = p.id
where p.role::text in ('admin', 'staff') and public.is_staff();

-- admin_bookings gets the new office columns (same name, new definition is ours).
create or replace view public.admin_bookings with (security_invoker = true) as
select b.id, b.booking_type, b.car_type, b.status, b.pickup_location, b.drop_location, b.rental_package,
       b.pickup_date, b.pickup_time, b.fare, b.advance_amount, b.customer_name, b.mobile,
       b.driver_id, b.created_at,
       (select d.full_name from public.drivers d where d.id = b.driver_id) as driver_name,
       (select bp.status from public.booking_payments bp
         where bp.booking_id = b.id order by bp.created_at desc limit 1)  as advance_status,
       b.source, b.handled_by, public.staff_name(b.handled_by) as handled_name, b.balance_collected
from public.bookings b;

-- ---------- staff management + performance ----------------------------
create function public.admin_set_staff(p_email text, p_role text, p_name text default null)
returns text language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_role not in ('admin', 'staff', 'customer') then raise exception 'role must be admin, staff or customer'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'No login with this email. Create it first in Supabase → Authentication → Users.'; end if;
  if uid = auth.uid() and p_role <> 'admin' then raise exception 'You cannot remove your own admin access.'; end if;
  insert into public.profiles (id, role, full_name) values (uid, p_role::public.user_role, nullif(trim(p_name), ''))
  on conflict (id) do update set role = excluded.role, full_name = coalesce(excluded.full_name, profiles.full_name);
  insert into public.activity_log (entity, entity_id, action, detail) values ('staff', uid, 'role', p_email || ' → ' || p_role);
  return uid::text;
end $$;

create function public.staff_performance(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 365));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(t) order by t.follow_ups desc) from (
      select s.id, coalesce(nullif(s.full_name, ''), s.email) as name, s.role,
             (select count(*) from enquiry_followups f where f.staff_id = s.id and f.created_at >= since and f.channel <> 'note') as follow_ups,
             (select count(*) from enquiry_followups f where f.staff_id = s.id and f.created_at >= since and f.outcome = 'booked') as converted,
             (select count(*) from enquiry_followups f where f.staff_id = s.id and f.created_at >= since and f.outcome in ('no_answer', 'busy')) as not_reached,
             (select count(*) from bookings b where b.created_by = s.id and b.created_at >= since) as bookings_created,
             (select count(*) from activity_log a where a.actor_id = s.id and a.entity = 'booking' and a.action = 'driver' and a.created_at >= since) as drivers_assigned,
             (select count(*) from enquiries e where e.assigned_to = s.id and e.status in ('new', 'contacted', 'follow_up')) as open_leads,
             (select count(*) from enquiries e where e.assigned_to = s.id and e.status in ('new', 'contacted', 'follow_up') and e.next_follow_up_at < now()) as overdue,
             (select max(a.created_at) from activity_log a where a.actor_id = s.id) as last_active
      from public.admin_staff s) t
  ), '[]'::jsonb);
end $$;

-- Lead counts per tab in one call.
create function public.lead_counts()
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'new',            count(*) filter (where status = 'new'),
    'due',            count(*) filter (where status in ('new', 'contacted', 'follow_up') and next_follow_up_at <= now()),
    'follow_up',      count(*) filter (where status = 'follow_up'),
    'contacted',      count(*) filter (where status = 'contacted'),
    'converted',      count(*) filter (where status = 'converted'),
    'not_interested', count(*) filter (where status = 'not_interested'),
    'invalid',        count(*) filter (where status = 'invalid'),
    'today',          count(*) filter (where created_at >= (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'))
  ) from public.enquiries
$$;

-- Dashboard + stats: staff may see them too.
create or replace function public.admin_dashboard()
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.is_staff() then raise exception 'staff only'; end if;
  return jsonb_build_object(
    'bookings_today',   (select count(*) from bookings where (created_at at time zone 'Asia/Kolkata')::date = today),
    'bookings_yesterday', (select count(*) from bookings where (created_at at time zone 'Asia/Kolkata')::date = today - 1),
    'pickups_today',    (select count(*) from bookings where pickup_date = today and status <> 'cancelled'),
    'pickups_no_driver',(select count(*) from bookings where pickup_date = today and status not in ('cancelled', 'completed') and driver_id is null),
    'advance_week',     (select coalesce(sum(amount_paid), 0) from booking_payments
                          where status = 'PAID' and paid_at >= now() - interval '7 days'),
    'enquiries_today',  (select count(*) from enquiries where (created_at at time zone 'Asia/Kolkata')::date = today),
    'leads_due',        (select count(*) from enquiries where status in ('new', 'contacted', 'follow_up') and coalesce(next_follow_up_at, created_at) <= now()),
    'leads_new',        (select count(*) from enquiries where status = 'new')
  );
end $$;

-- ---------- security ---------------------------------------------------
alter table public.enquiry_followups enable row level security;
alter table public.activity_log      enable row level security;

-- Staff work on leads, bookings, customers; read drivers, cars, payments, catalogue.
do $$
declare t text;
begin
  foreach t in array array['enquiries', 'enquiry_followups', 'bookings', 'customers']
  loop
    execute format('create policy "staff all %1$s" on public.%1$I for all using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
  foreach t in array array['drivers', 'vehicles', 'booking_payments', 'booking_status_history', 'activity_log', 'profiles', 'settings']
  loop
    execute format('create policy "staff read %1$s" on public.%1$I for select using (public.is_staff())', t);
  end loop;
end $$;
create policy "staff write activity" on public.activity_log for insert with check (public.is_staff() and actor_id = auth.uid());

revoke all on public.enquiry_followups, public.activity_log, public.admin_enquiries, public.admin_activity, public.admin_staff from anon;
grant select, insert on public.enquiry_followups to authenticated;
grant select, insert on public.activity_log to authenticated;
grant select on public.admin_enquiries, public.admin_activity, public.admin_staff to authenticated;
revoke execute on function public.admin_set_staff(text, text, text), public.staff_performance(int), public.lead_counts() from anon, public;
grant execute on function public.admin_set_staff(text, text, text), public.staff_performance(int), public.lead_counts() to authenticated;

commit;
