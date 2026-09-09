/** Minimal billing ledger. Never includes subscriber attributes, health data, email or ad IDs. */
export function billingRow(event: Record<string, unknown>) {
  const text = (key: string) => typeof event[key] === "string" ? (event[key] as string).slice(0, 256) : null;
  const strings = (key: string) => Array.isArray(event[key])
    ? (event[key] as unknown[]).filter((x): x is string => typeof x === "string").slice(0, 100).map(x => x.slice(0, 256)) : [];
  const date = (key: string) => {
    const n = event[key];
    if (typeof n !== "number" || !Number.isFinite(n) || n <= 0 || n > 8_640_000_000_000_000) return null;
    return new Date(n).toISOString();
  };
  if (!text("id") || !text("type") || !date("event_timestamp_ms")) return null;
  return {
    event_id: text("id"), event_type: text("type"), app_user_id: text("app_user_id"),
    aliases: strings("aliases"), original_transaction_id: text("original_transaction_id"), product_id: text("product_id"),
    entitlement_ids: strings("entitlement_ids"), environment: text("environment"),
    period_type: text("period_type"), occurred_at: date("event_timestamp_ms"),
    purchased_at: date("purchased_at_ms"), expires_at: date("expiration_at_ms"),
    is_trial_conversion: event.is_trial_conversion === true,
  };
}

export async function recordBilling(event: Record<string, unknown>): Promise<boolean> {
  if (event.type === "TEST") return true;
  const row = billingRow(event);
  if (!row) return false;
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return false;
  try {
    const response = await fetch(`${url}/rest/v1/subscription_events?on_conflict=event_id`, {
      method: "POST",
      headers: { apikey: key, authorization: `Bearer ${key}`, "content-type": "application/json", prefer: "resolution=ignore-duplicates,return=minimal" },
      body: JSON.stringify(row),
    });
    return response.ok;
  } catch { return false; }
}
