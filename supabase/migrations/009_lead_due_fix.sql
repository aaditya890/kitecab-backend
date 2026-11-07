-- =====================================================================
-- KiteCab v2 — "Call now" counts new leads that have no follow-up time yet
-- (same rule as the Enquiries list). Admin login gets a display name.
-- =====================================================================
begin;

create or replace function public.lead_counts()
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'new',            count(*) filter (where status = 'new'),
    'due',            count(*) filter (where status in ('new', 'contacted', 'follow_up') and (next_follow_up_at is null or next_follow_up_at <= now())),
    'follow_up',      count(*) filter (where status = 'follow_up'),
    'contacted',      count(*) filter (where status = 'contacted'),
    'converted',      count(*) filter (where status = 'converted'),
    'not_interested', count(*) filter (where status = 'not_interested'),
    'invalid',        count(*) filter (where status = 'invalid'),
    'today',          count(*) filter (where created_at >= (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'))
  ) from public.enquiries
$$;

update public.profiles p set full_name = 'KiteCab Admin'
from auth.users u
where u.id = p.id and u.email = 'kitecabtaxiservice@gmail.com' and coalesce(p.full_name, '') = '';

commit;
