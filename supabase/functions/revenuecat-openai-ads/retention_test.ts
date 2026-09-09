import { billingRow } from "./retention.ts";
const assert = (value: boolean) => { if (!value) throw new Error("Assertion failed"); };
Deno.test("billing ledger keeps cancellations and sandbox distinct", () => {
  const row = billingRow({ id: "e1", type: "CANCELLATION", event_timestamp_ms: 1788894000000,
    environment: "SANDBOX", period_type: "TRIAL", subscriber_attributes: { email: "private" } });
  assert(row?.event_type === "CANCELLATION" && row?.environment === "SANDBOX");
  assert(!JSON.stringify(row).includes("private"));
  assert(row?.is_trial_conversion === false);
});
Deno.test("only explicit conversion flag counts and invalid dates fail", () => {
  assert(billingRow({ id: "e", type: "RENEWAL", event_timestamp_ms: Infinity }) === null);
  const row = billingRow({ id: "e", type: "RENEWAL", event_timestamp_ms: 1788894000000, is_trial_conversion: true });
  assert(row?.is_trial_conversion === true);
});
Deno.test("untrusted array elements and extra fields are excluded", () => {
  const row = billingRow({ id: "e", type: "INITIAL_PURCHASE", event_timestamp_ms: 1788894000000,
    aliases: ["uuid", {}, 12], route: "private health route", notes: "pain" });
  assert(row?.aliases.length === 1 && !JSON.stringify(row).includes("pain"));
});
