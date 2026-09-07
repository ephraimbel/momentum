// Pure mapping from a RevenueCat webhook event to an OpenAI Ads conversion (no I/O), so the
// rules are unit-tested with `deno test` and the handler in index.ts stays a thin shell.
//
// Two conversions leave here, never more per subscriber:
//   • `trial_started`        — INITIAL_PURCHASE with period_type TRIAL (free; no amount). The
//                              optimisation signal a click campaign can learn from in days.
//   • `subscription_created` — a paid start: a non-trial INITIAL_PURCHASE with a price, or the
//                              RENEWAL RevenueCat emits when a trial converts. Ordinary renewals
//                              are excluded so one subscriber is counted once.

export type RevenueCatEvent = {
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

export type ConversionKind = "trial_started" | "subscription_created";

const zeroDecimalCurrencies = new Set([
  "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF",
  "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
]);

/** Which conversion, if any, this RevenueCat event is. */
export function classify(event: RevenueCatEvent): ConversionKind | null {
  if (event.type === "INITIAL_PURCHASE") {
    if (event.period_type === "TRIAL") return "trial_started";
    return (event.price_in_purchased_currency ?? event.price ?? 0) > 0 ? "subscription_created" : null;
  }
  // RevenueCat emits RENEWAL when a free trial becomes a paid subscription.
  if (event.type === "RENEWAL" && event.is_trial_conversion === true) return "subscription_created";
  return null;
}

export function amountInMinorUnits(event: RevenueCatEvent): number | undefined {
  const price = event.price_in_purchased_currency ?? event.price;
  const currency = event.currency?.toUpperCase();
  if (price == null || price <= 0 || !currency) return undefined;
  return Math.round(price * (zeroDecimalCurrencies.has(currency) ? 1 : 100));
}

export async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value.trim());
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** The OpenAI Ads event for a classified RevenueCat event (plan_enrollment shape). */
export async function buildConversion(
  event: RevenueCatEvent,
  kind: ConversionKind,
  now: number = Date.now(),
): Promise<Record<string, unknown>> {
  const data: Record<string, unknown> = {
    type: "plan_enrollment",
    plan_id: event.product_id ?? "momentum_pro",
  };
  // A trial is free: no amount, so the optimiser never learns a $0 "purchase".
  if (kind === "subscription_created") {
    const amount = amountInMinorUnits(event);
    const currency = event.currency?.toUpperCase();
    if (amount != null && currency) {
      data.amount = amount;
      data.currency = currency;
    }
  }

  const user: Record<string, unknown> = {};
  const customerID = event.app_user_id ?? event.original_app_user_id;
  if (customerID) user.external_ids_sha256 = [await sha256(customerID)];
  if (event.country_code) user.countries = [event.country_code.toUpperCase()];

  return {
    id: `revenuecat_${event.id}`,
    type: kind,
    timestamp_ms: event.purchased_at_ms ?? event.event_timestamp_ms ?? now,
    action_source: "mobile_app",
    ...(Object.keys(user).length ? { user } : {}),
    data,
  };
}
