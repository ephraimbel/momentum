import { assertEquals } from "jsr:@std/assert@1";
import { amountInMinorUnits, buildConversion, classify, type RevenueCatEvent } from "./conversion.ts";

const base: RevenueCatEvent = {
  id: "evt_1", app_user_id: "$RCAnonymousID:abc", product_id: "momentum_pro_yearly",
  environment: "PRODUCTION", entitlement_ids: ["pro"], country_code: "us",
  event_timestamp_ms: 1_757_000_000_000, purchased_at_ms: 1_757_000_000_000,
};

Deno.test("a trial start is its own event and a paid start is the conversion", () => {
  assertEquals(classify({ ...base, type: "INITIAL_PURCHASE", period_type: "TRIAL", price: 0 }), "trial_started");
  assertEquals(classify({ ...base, type: "INITIAL_PURCHASE", period_type: "NORMAL", price_in_purchased_currency: 5.99, currency: "USD" }), "subscription_created");
  assertEquals(classify({ ...base, type: "RENEWAL", is_trial_conversion: true, price: 79.99, currency: "USD" }), "subscription_created");
});

Deno.test("ordinary renewals, free non-trial purchases and everything else are dropped", () => {
  assertEquals(classify({ ...base, type: "RENEWAL", is_trial_conversion: false, price: 5.99 }), null);
  assertEquals(classify({ ...base, type: "RENEWAL", price: 5.99 }), null);
  assertEquals(classify({ ...base, type: "INITIAL_PURCHASE", period_type: "NORMAL", price: 0 }), null);
  assertEquals(classify({ ...base, type: "CANCELLATION" }), null);
  assertEquals(classify({ ...base, type: "PRODUCT_CHANGE", price: 79.99 }), null);
});

Deno.test("a trial carries no amount; a paid start carries minor units and currency", async () => {
  const trial = await buildConversion({ ...base, type: "INITIAL_PURCHASE", period_type: "TRIAL", price: 0, currency: "USD" }, "trial_started");
  assertEquals(trial.type, "trial_started");
  assertEquals(trial.data, { type: "plan_enrollment", plan_id: "momentum_pro_yearly" });
  assertEquals(trial.action_source, "mobile_app");
  assertEquals(trial.id, "revenuecat_evt_1");
  assertEquals(trial.timestamp_ms, 1_757_000_000_000);
  assertEquals((trial.user as Record<string, unknown>).countries, ["US"]);

  const paid = await buildConversion({ ...base, type: "RENEWAL", is_trial_conversion: true, price: 79.99, currency: "usd" }, "subscription_created");
  assertEquals(paid.type, "subscription_created");
  assertEquals(paid.data, { type: "plan_enrollment", plan_id: "momentum_pro_yearly", amount: 7999, currency: "USD" });
});

Deno.test("minor units respect zero-decimal currencies", () => {
  assertEquals(amountInMinorUnits({ price: 1200, currency: "JPY" }), 1200);
  assertEquals(amountInMinorUnits({ price: 5.99, currency: "USD" }), 599);
  assertEquals(amountInMinorUnits({ price: 0, currency: "USD" }), undefined);
  assertEquals(amountInMinorUnits({ price: 5.99 }), undefined);
});

Deno.test("the hashed external id is stable and the plan falls back to momentum_pro", async () => {
  const a = await buildConversion({ ...base, product_id: undefined, type: "INITIAL_PURCHASE", period_type: "TRIAL" }, "trial_started");
  const b = await buildConversion({ ...base, product_id: undefined, type: "INITIAL_PURCHASE", period_type: "TRIAL" }, "trial_started");
  assertEquals((a.user as Record<string, unknown>).external_ids_sha256, (b.user as Record<string, unknown>).external_ids_sha256);
  assertEquals((a.data as Record<string, unknown>).plan_id, "momentum_pro");
});
