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

import Stripe from "https://esm.sh/stripe@14?target=denonext";
import { adminClient } from "../_shared/supabase.ts";
import { rolloutEnabled } from "../_shared/internal_auth.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
  maxNetworkRetries: 1,
  timeout: 8000,
});
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method_not_allowed", { status: 405 });
  }
  if (!rolloutEnabled("PAYMENT_WEBHOOK_ENABLED")) {
    return new Response("disabled", { status: 503 });
  }
  if (!webhookSecret || !Deno.env.get("STRIPE_SECRET_KEY")) {
    return new Response("stripe_not_configured", { status: 503 });
  }

  const signature = req.headers.get("stripe-signature");
  const body = await req.text();
  if (!signature) {
    return new Response("missing signature", { status: 400 });
  }

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      webhookSecret,
    );
  } catch {
    return new Response("bad signature", { status: 400 });
  }

  const supabase = adminClient();

  switch (event.type) {
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      // Re-read Stripe's canonical current object. Signed events can arrive
      // out of order, so applying the embedded historical snapshot directly
      // could regress a member's subscription state.
      const delivered = event.data.object as Stripe.Subscription;
      const sub = await stripe.subscriptions.retrieve(delivered.id);
      const customer = await stripe.customers.retrieve(sub.customer as string);
      const userId = (customer as Stripe.Customer).metadata?.user_id;
      if (!userId) {
        console.error("Stripe customer mapping missing");
        return new Response("customer_mapping_missing", { status: 500 });
      }
      const price = sub.items.data[0]?.price;
      const tier = priceToTier(price?.id);
      if (!tier) {
        console.error("Stripe price mapping missing");
        return new Response("price_mapping_missing", { status: 500 });
      }
      const applied = await supabase.rpc("apply_stripe_subscription_event", {
        p_event_id: event.id,
        p_event_created: event.created,
        p_event_type: event.type,
        p_subscription_id: sub.id,
        p_user_id: userId,
        p_customer_id: sub.customer as string,
        p_status: sub.status,
        p_tier: tier,
        p_price_id: price?.id ?? null,
        p_renews_at: asIso(sub.current_period_end),
        p_canceled_at: asIso(sub.canceled_at),
        p_period_start: asIso(sub.current_period_start),
        p_period_end: asIso(sub.current_period_end),
      });
      if (applied.error) {
        return new Response("subscription_update_failed", { status: 500 });
      }
      break;
    }
    case "invoice.payment_succeeded":
    case "invoice.payment_failed":
      // No mutation here. The canonical subscription.* event owns state.
      break;
    default:
      break;
  }

  return new Response("ok");
});

/**
 * Maps a Stripe price id to a tier slug. Configure these in the env or
 * pull from a `stripe_prices` table once you have multiple products.
 */
function priceToTier(priceId: string | undefined): string | null {
  if (!priceId) return null;
  const plus = Deno.env.get("STRIPE_PRICE_PLUS");
  const pro = Deno.env.get("STRIPE_PRICE_PRO");
  const creator = Deno.env.get("STRIPE_PRICE_CREATOR");
  if (priceId === plus) return "plus";
  if (priceId === pro) return "pro";
  if (priceId === creator) return "creator";
  return null;
}

function asIso(timestamp: number | null | undefined): string | null {
  return timestamp ? new Date(timestamp * 1000).toISOString() : null;
}
