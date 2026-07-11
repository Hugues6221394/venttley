// Shared CORS headers for every Edge Function. Tighten the allowed
// origin in production once the marketing site + mobile redirect URLs
// are pinned down.

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

export function handleOptions(): Response | null {
  return new Response('ok', { headers: corsHeaders });
}
