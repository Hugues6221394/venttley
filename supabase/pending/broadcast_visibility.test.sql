-- PREPARED, NOT RUN. Disposable test database after applying paired draft.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT no_plan();
-- Fixture insertion bypasses publication guard only in this rolled-back test.
SET session_replication_role=replica;
INSERT INTO public.broadcasts(broadcast_id,title,body,urgency,audience,is_active,sent_at,scheduled_for,expires_at)
SELECT ('2b792000-0000-4000-8000-'||lpad(n::TEXT,12,'0'))::UUID,'visibility fixture','Synthetic','info',audience,active,sent,scheduled,expires
FROM (VALUES
 (1,'{"scope":"all"}'::JSONB,true,now()-interval '1 minute',NULL::TIMESTAMPTZ,now()+interval '1 day'),
 (2,'{"scope":"tribe","value":"hidden"}'::JSONB,true,now(),NULL::TIMESTAMPTZ,NULL::TIMESTAMPTZ),
 (3,'{"scope":"region","value":"RW"}'::JSONB,true,now(),NULL::TIMESTAMPTZ,NULL::TIMESTAMPTZ),
 (4,'{"scope":"role","value":"admin"}'::JSONB,true,now(),NULL::TIMESTAMPTZ,NULL::TIMESTAMPTZ),
 (5,'{"scope":"all"}'::JSONB,true,NULL::TIMESTAMPTZ,now()+interval '1 day',NULL::TIMESTAMPTZ),
 (6,'{"scope":"all"}'::JSONB,true,now(),now()+interval '1 day',NULL::TIMESTAMPTZ),
 (7,'{"scope":"all"}'::JSONB,true,now(),NULL::TIMESTAMPTZ,now()-interval '1 second'),
 (8,'{"scope":"all"}'::JSONB,false,now(),NULL::TIMESTAMPTZ,NULL::TIMESTAMPTZ),
 (9,'{"scope":"all","value":"private"}'::JSONB,true,now(),NULL::TIMESTAMPTZ,NULL::TIMESTAMPTZ),
 (10,'{"scope":"all"}'::JSONB,true,now()+interval '1 day',NULL::TIMESTAMPTZ,NULL::TIMESTAMPTZ)
)t(n,audience,active,sent,scheduled,expires);
SET session_replication_role=origin;
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='visibility fixture'),1,'anonymous sees only published current global message');
RESET ROLE;
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"2b792000-1111-4111-8111-000000000001"}',true);
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='visibility fixture'),1,'unprivileged account does not inherit staff inspection rights');
RESET ROLE;
CREATE POLICY test_accidental_broad_read ON public.broadcasts FOR SELECT TO anon USING(true);
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::INT FROM public.broadcasts WHERE title='visibility fixture'),1,'restrictive boundary survives additional permissive policy');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
