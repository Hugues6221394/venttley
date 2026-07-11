// payment-webhook
//
// Receives Stripe webhook events and mirrors subscription state into
// the `subscriptions` table. The Flutter app reads from this table —
// Stripe is never the source of truth at runtime.
//
// Env:
//   STRIPE_SECRET_KEY        — sk_live_… or sk_test_…
//   STRIPE_WEBHOOK_SECRET    — whsec_… (from the webhook endpoint)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
//
// Setup: point a Stripe webhook endpoint at this function URL and
// subscribe to: customer.subscription.created / updated / deleted +
// invoice.payment_succeeded / invoice.payment_failed.

import Stripe from 'https://esm.sh/stripe@14?target=denonext';
import { adminClient } from '../_shared/supabase.ts';
import { corsHeaders, handleOptions } from '../_shared/cors.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
});
const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return handleOptions()!;

  const signature = req.headers.get('stripe-signature');
  const body = await req.text();
  if (!signature) {
    return new Response('missing signature', { status: 400, headers: corsHeaders });
  }

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature, webhookSecret);
  } catch (e) {
    return new Response(`bad signature: ${e}`, { status: 400, headers: corsHeaders });
  }

  const supabase = adminClient();

  switch (event.type) {
    case 'customer.subscription.created':
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const sub = event.data.object as Stripe.Subscription;
      const customer = await stripe.customers.retrieve(sub.customer as string);
      const userId = (customer as Stripe.Customer).metadata?.user_id;
      if (!userId) {
        return new Response('customer missing user_id metadata', {
          status: 200,
          headers: corsHeaders,
        });
      }
      const price = sub.items.data[0]?.price;
      const tier = priceToTier(price?.id);
      await supabase
        .from('subscriptions')
        .upsert({
          subscription_id:        sub.id,
          user_id:                userId,
          stripe_customer_id:     sub.customer as string,
          status:                 sub.status,
          tier,
          price_id:               price?.id,
          renews_at:              sub.current_period_end
            ? new Date(sub.current_period_end * 1000).toISOString()
            : null,
          canceled_at: sub.canceled_at
            ? new Date(sub.canceled_at * 1000).toISOString()
            : null,
          current_period_start: sub.current_period_start
            ? new Date(sub.current_period_start * 1000).toISOString()
            : null,
          current_period_end: sub.current_period_end
            ? new Date(sub.current_period_end * 1000).toISOString()
            : null,
          updated_at: new Date().toISOString(),
        });
      break;
    }
    case 'invoice.payment_succeeded':
    case 'invoice.payment_failed':
      // Surface as a notification + audit row. The subscription itself
      // is already updated via the subscription.* event that follows.
      break;
    default:
      break;
  }

  return new Response('ok', { headers: corsHeaders });
});

/**
 * Maps a Stripe price id to a tier slug. Configure these in the env or
 * pull from a `stripe_prices` table once you have multiple products.
 */
function priceToTier(priceId: string | undefined): string {
  if (!priceId) return 'free';
  const plus = Deno.env.get('STRIPE_PRICE_PLUS');
  const pro = Deno.env.get('STRIPE_PRICE_PRO');
  const creator = Deno.env.get('STRIPE_PRICE_CREATOR');
  if (priceId === plus) return 'plus';
  if (priceId === pro) return 'pro';
  if (priceId === creator) return 'creator';
  return 'free';
}
