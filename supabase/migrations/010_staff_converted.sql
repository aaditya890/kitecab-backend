-- =====================================================================
-- KiteCab v2 — "Leads booked" counts bookings a person made from a lead,
-- plus leads they marked Booked (the same lead is never counted twice).
-- =====================================================================
begin;

create or replace function public.staff_performance(p_days int default 7)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - make_interval(days => least(greatest(p_days, 1), 365));
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return coalesce((
    select jsonb_agg(row_to_json(t) order by t.follow_ups desc) from (
      select s.id, coalesce(nullif(s.full_name, ''), s.email) as name, s.role,
             (select count(*) from enquiry_followups f where f.staff_id = s.id and f.created_at >= since and f.channel <> 'note') as follow_ups,
             (select count(*) from bookings b where b.created_by = s.id and b.enquiry_id is not null and b.created_at >= since)
             + (select count(*) from enquiry_followups f where f.staff_id = s.id and f.created_at >= since and f.outcome = 'booked'
                  and not exists (select 1 from bookings b2 where b2.enquiry_id = f.enquiry_id and b2.created_by = s.id)) as converted,
             (select count(*) from enquiry_followups f where f.staff_id = s.id and f.created_at >= since and f.outcome in ('no_answer', 'busy')) as not_reached,
             (select count(*) from bookings b where b.created_by = s.id and b.created_at >= since) as bookings_created,
             (select count(*) from activity_log a where a.actor_id = s.id and a.entity = 'booking' and a.action = 'driver' and a.created_at >= since) as drivers_assigned,
             (select count(*) from enquiries e where e.assigned_to = s.id and e.status in ('new', 'contacted', 'follow_up')) as open_leads,
             (select count(*) from enquiries e where e.assigned_to = s.id and e.status in ('new', 'contacted', 'follow_up') and e.next_follow_up_at < now()) as overdue,
             (select max(a.created_at) from activity_log a where a.actor_id = s.id) as last_active
      from public.admin_staff s) t
  ), '[]'::jsonb);
end $$;

commit;
