-- =====================================================================
-- READ-ONLY check of the LIVE tables (`kitecab`, `payments`).
-- Run it BEFORE and AFTER setup_v2.sql and compare the two results.
--   * "structure" rows must be IDENTICAL (columns, indexes, policies, triggers).
--   * "data" rows change only if a customer booked on kitecab.com in between.
-- Changes nothing.
-- =====================================================================
select 'kitecab data' as what, count(*)::text as count, md5(string_agg(t::text, '|' order by t.id)) as fingerprint
from public.kitecab t
union all
select 'payments data', count(*)::text, md5(string_agg(p::text, '|' order by p.id))
from public.payments p
union all
select 'structure: columns', count(*)::text,
       md5(string_agg(table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, ''),
                      '|' order by table_name, ordinal_position))
from information_schema.columns
where table_schema = 'public' and table_name in ('kitecab', 'payments')
union all
select 'structure: indexes', count(*)::text, md5(coalesce(string_agg(indexdef, '|' order by indexname), ''))
from pg_indexes
where schemaname = 'public' and tablename in ('kitecab', 'payments')
union all
select 'structure: policies', count(*)::text, md5(coalesce(string_agg(tablename || policyname || cmd || coalesce(qual, ''), '|' order by tablename, policyname), ''))
from pg_policies
where schemaname = 'public' and tablename in ('kitecab', 'payments')
union all
select 'structure: triggers', count(*)::text, md5(coalesce(string_agg(tgname, '|' order by tgname), ''))
from pg_trigger
where not tgisinternal and tgrelid in ('public.kitecab'::regclass, 'public.payments'::regclass)
union all
select 'structure: grants', count(*)::text, md5(coalesce(string_agg(table_name || grantee || privilege_type, '|' order by table_name, grantee, privilege_type), ''))
from information_schema.role_table_grants
where table_schema = 'public' and table_name in ('kitecab', 'payments');
