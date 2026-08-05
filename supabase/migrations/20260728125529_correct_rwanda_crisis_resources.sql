-- Correct crisis contacts after verifying official Rwanda sources.
--
-- 741741 is not a Venttly service and must not be presented as a global
-- fallback. The Ministry of Health publishes 114/912 as health emergency
-- numbers, while the Kigali Mental Health Referral Centre publishes its own
-- contact numbers. Avoid claiming that any line is 24/7, confidential, or
-- mental-health-specific unless the source explicitly says so.

UPDATE public.crisis_resources
   SET is_active = false
 WHERE label = 'Venttly Care Line'
    OR reach ILIKE '%741741%'
    OR label = 'Crisis Text Line';

UPDATE public.crisis_resources
   SET label = 'Rwanda health emergency',
       reach = 'Call 114 or 912',
       url = 'https://www.moh.gov.rw/contact',
       hours = 'Emergency',
       sort_order = 10
 WHERE region = 'RW'
   AND (reach ILIKE 'Call 114%' OR label ILIKE '%Mental Health Helpline%');

UPDATE public.crisis_resources
   SET label = 'Isange One Stop Centre (GBV and child abuse)',
       reach = 'Call 3029',
       url = 'https://police.gov.rw/',
       hours = 'Toll-free line',
       sort_order = 20
 WHERE region = 'RW'
   AND (reach ILIKE '%3029%' OR label ILIKE 'Isange%');

INSERT INTO public.crisis_resources (
  region,
  label,
  reach,
  url,
  hours,
  sort_order
)
SELECT
  'RW',
  'Kigali Mental Health Referral Centre',
  'Call 0793902059 or 0736440666',
  'https://www.kmentalhealth.gov.rw/',
  'Contact centre',
  5
WHERE NOT EXISTS (
  SELECT 1
    FROM public.crisis_resources
   WHERE region = 'RW'
     AND label = 'Kigali Mental Health Referral Centre'
);

NOTIFY pgrst, 'reload schema';
