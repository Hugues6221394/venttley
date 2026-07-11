-- 0095_crisis_bodies_rw.sql
-- Name Rwanda's approved crisis-escalation bodies explicitly for suicide/
-- self-harm cases: the Ministry of Health mental-health helpline (114) and
-- Isange One Stop Centre (3029). These are a HEALTH matter — never RIB (which
-- is CSAM/crime only, migration 0094). Float both to the top of the in-app
-- crisis resources list. Idempotent.

-- Make the MoH association explicit on the 114 line.
UPDATE public.crisis_resources
   SET label = 'Ministry of Health — Mental Health Helpline',
       sort_order = 5
 WHERE region = 'RW' AND reach LIKE 'Call 114%';

-- Isange right behind it.
UPDATE public.crisis_resources
   SET sort_order = 6
 WHERE region = 'RW' AND label LIKE 'Isange%';

-- Safety net: insert the MoH line if it isn't present for any reason.
INSERT INTO public.crisis_resources (region, label, reach, url, hours, sort_order)
SELECT 'RW', 'Ministry of Health — Mental Health Helpline',
       'Call 114 (free, 24/7)', NULL, '24/7', 5
 WHERE NOT EXISTS (
    SELECT 1 FROM public.crisis_resources
     WHERE region = 'RW' AND reach LIKE 'Call 114%'
 );

INSERT INTO public.crisis_resources (region, label, reach, url, hours, sort_order)
SELECT 'RW', 'Isange One Stop Centre',
       'Call 3029 from any phone', 'https://rib.gov.rw/isange', '24/7', 6
 WHERE NOT EXISTS (
    SELECT 1 FROM public.crisis_resources
     WHERE region = 'RW' AND label LIKE 'Isange%'
 );

NOTIFY pgrst, 'reload schema';
