// Supabase Edge Function: revenuecat-openai-ads
//
// Receives authenticated RevenueCat webhooks and forwards two kinds of event to the OpenAI Ads
// Conversions API: `trial_started` for a free-trial start (the fast optimisation signal a click
// campaign can learn from in days) and `subscription_created` for a verified paid start — a
// non-trial purchase, or the renewal RevenueCat emits when a trial converts. The rules live in
// conversion.ts and are unit-tested (`deno test`). Deploy with `--no-verify-jwt`; RevenueCat
// authenticates with REVENUECAT_WEBHOOK_SECRET.

import { buildConversion, classify, type RevenueCatEvent } from "./conversion.ts";

import { recordBilling } from "./retention.ts";

const OPENAI_EVENTS_URL = "https://bzr.openai.com/v1/events";

type RevenueCatPayload = {
  api_version?: string;
  event?: RevenueCatEvent;
};

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

  // Persist all billing transitions before classifying advertising conversions. Duplicate
  // deliveries are ignored by event ID. A write failure asks RevenueCat to retry.
  if (!await recordBilling(event as unknown as Record<string, unknown>)) {
    return json(503, { error: "billing_ledger_unavailable" });
  }

  // The dashboard's "Send test event" validates the paid shape against OpenAI without recording.
  const isDashboardTest = event.type === "TEST";
  let kind = "subscription_created" as ReturnType<typeof classify>;
  if (!isDashboardTest) {
    if (event.environment !== "PRODUCTION") return json(200, { forwarded: false, reason: "non_production" });
    if (!event.entitlement_ids?.includes("pro")) return json(200, { forwarded: false, reason: "non_pro_entitlement" });
    kind = classify(event);
    if (!kind) return json(200, { forwarded: false, reason: "not_a_subscription_start" });
  }

  const conversion = await buildConversion(event, kind!, Date.now());
  if (isDashboardTest) conversion.timestamp_ms = Date.now();

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
    console.error("[revenuecat-openai-ads] OpenAI rejected event", kind, response.status, responseText);
    return json(502, { error: "conversion_rejected", upstream_status: response.status });
  }

  return json(200, {
    forwarded: !isDashboardTest,
    validated: isDashboardTest,
    kind,
    revenuecat_event_id: event.id,
  });
});
