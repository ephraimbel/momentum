// Supabase Edge Function: revenuecat-openai-ads
//
// Receives authenticated RevenueCat webhooks and forwards verified paid
// subscription starts to the OpenAI Ads Conversions API. Deploy with
// `--no-verify-jwt`; RevenueCat authenticates with REVENUECAT_WEBHOOK_SECRET.

const OPENAI_EVENTS_URL = "https://bzr.openai.com/v1/events";

type RevenueCatEvent = {
  id?: string;
  type?: string;
  app_user_id?: string;
  original_app_user_id?: string;
  product_id?: string;
  period_type?: string;
  environment?: string;
  entitlement_ids?: string[] | null;
  event_timestamp_ms?: number;
  purchased_at_ms?: number;
  price_in_purchased_currency?: number | null;
  price?: number | null;
  currency?: string | null;
  country_code?: string | null;
  is_trial_conversion?: boolean;
};

type RevenueCatPayload = {
  api_version?: string;
  event?: RevenueCatEvent;
};

const zeroDecimalCurrencies = new Set([
  "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF",
  "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
]);

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function bearerToken(req: Request): string {
  const authorization = req.headers.get("authorization") ?? "";
  return authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value.trim());
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function paidSubscriptionStart(event: RevenueCatEvent): boolean {
  if (event.type === "INITIAL_PURCHASE") {
    return event.period_type !== "TRIAL" && (event.price_in_purchased_currency ?? event.price ?? 0) > 0;
  }

  // RevenueCat emits RENEWAL when a free trial becomes a paid subscription.
  // Ordinary renewals are intentionally excluded so one subscriber is counted once.
  return event.type === "RENEWAL" && event.is_trial_conversion === true;
}

function amountInMinorUnits(event: RevenueCatEvent): number | undefined {
  const price = event.price_in_purchased_currency ?? event.price;
  const currency = event.currency?.toUpperCase();
  if (price == null || price <= 0 || !currency) return undefined;
  return Math.round(price * (zeroDecimalCurrencies.has(currency) ? 1 : 100));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const webhookSecret = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
  const conversionKey = Deno.env.get("OPENAI_ADS_CONVERSION_KEY") ?? "";
  const pixelID = Deno.env.get("OPENAI_ADS_PIXEL_ID") ?? "";

  if (!webhookSecret || !conversionKey || !pixelID) {
    console.error("[revenuecat-openai-ads] missing required secrets");
    return json(503, { error: "not_configured" });
  }

  if (bearerToken(req) !== webhookSecret) return json(401, { error: "unauthorized" });

  let payload: RevenueCatPayload;
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const event = payload.event;
  if (!event?.id || !event.type) return json(400, { error: "invalid_revenuecat_event" });

  const isDashboardTest = event.type === "TEST";
  if (!isDashboardTest) {
    if (event.environment !== "PRODUCTION") return json(200, { forwarded: false, reason: "non_production" });
    if (!event.entitlement_ids?.includes("pro")) return json(200, { forwarded: false, reason: "non_pro_entitlement" });
    if (!paidSubscriptionStart(event)) return json(200, { forwarded: false, reason: "not_paid_subscription_start" });
  }

  const customerID = event.app_user_id ?? event.original_app_user_id;
  const currency = event.currency?.toUpperCase();
  const amount = amountInMinorUnits(event);
  const data: Record<string, unknown> = {
    type: "plan_enrollment",
    plan_id: event.product_id ?? "momentum_pro",
  };
  if (amount != null && currency) {
    data.amount = amount;
    data.currency = currency;
  }

  const user: Record<string, unknown> = {};
  if (customerID) user.external_ids_sha256 = [await sha256(customerID)];
  if (event.country_code) user.countries = [event.country_code.toUpperCase()];

  const conversion = {
    id: `revenuecat_${event.id}`,
    type: "subscription_created",
    timestamp_ms: isDashboardTest
      ? Date.now()
      : (event.purchased_at_ms ?? event.event_timestamp_ms ?? Date.now()),
    action_source: "mobile_app",
    ...(Object.keys(user).length ? { user } : {}),
    data,
  };

  const response = await fetch(`${OPENAI_EVENTS_URL}?pid=${encodeURIComponent(pixelID)}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${conversionKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      validate_only: isDashboardTest,
      integration_source: "momentum_revenuecat",
      events: [conversion],
    }),
  });

  const responseText = await response.text();
  if (!response.ok) {
    console.error("[revenuecat-openai-ads] OpenAI rejected event", response.status, responseText);
    return json(502, { error: "conversion_rejected", upstream_status: response.status });
  }

  return json(200, {
    forwarded: !isDashboardTest,
    validated: isDashboardTest,
    revenuecat_event_id: event.id,
  });
});
