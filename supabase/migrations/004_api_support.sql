-- =====================================================================
-- KiteCab v2 — columns used by the Vercel API
-- ip_hash: salted SHA-256 of the client IP (raw IPs are never stored),
--          used only for spam limits.
-- =====================================================================
begin;
alter table public.enquiries add column if not exists ip_hash text;
alter table public.bookings  add column if not exists ip_hash text;

create index if not exists enquiries_ip_recent_idx     on public.enquiries (ip_hash, created_at desc);
create index if not exists enquiries_mobile_recent_idx on public.enquiries (mobile, created_at desc);
create index if not exists bookings_ip_recent_idx      on public.bookings  (ip_hash, created_at desc);

-- how many payment links were issued for a booking (admin "new link" uses attempt+1)
alter table public.payments add column if not exists attempt int not null default 1;

commit;
