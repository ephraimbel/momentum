// Supabase Edge Function: garmin-webhook (docs/WEARABLES-DIRECT.md)
//
// Garmin's Push Service POSTs here whenever a connected athlete syncs an activity. Contract:
// respond 200 FAST (Garmin times out slow endpoints and retries failures) — so this function
// only STAGES rows into `vendor_activities` and returns. The app imports from the staging inbox
// on next foreground, running the same overlap dedupe as the HealthKit importer (a Garmin run
// usually also reaches Apple Health via Garmin Connect — the physical run must import ONCE).
//
// Deploy:  supabase functions deploy garmin-webhook --no-verify-jwt
//          (Garmin cannot send a Supabase JWT. Authenticity comes from the payload's
//           userId → vendor_connections join: unknown users are dropped.)
//
// Register this URL in the Garmin developer portal (Push/Ping config, "Activities" summary):
//   https://<project-ref>.supabase.co/functions/v1/garmin-webhook
//
// Payload shape (Activity Push): { "activities": [ ActivitySummary, ... ] } — each summary has
// userId, summaryId, activityType, startTimeInSeconds, durationInSeconds, distanceInMeters,
// averageHeartRateInBeatsPerMinute, totalElevationGainInMeters, … We keep the whole object in
// `summary` jsonb so unmodeled fields (cadence, laps, running dynamics) aren't lost.

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, // service role: staging inserts bypass RLS
);

interface GarminActivity {
  userId: string;
  summaryId: string;
  activityType?: string;
  startTimeInSeconds?: number;
  durationInSeconds?: number;
  distanceInMeters?: number;
  averageHeartRateInBeatsPerMinute?: number;
  totalElevationGainInMeters?: number;
  [key: string]: unknown;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });

  let payload: { activities?: GarminActivity[]; deregistrations?: { userId: string }[] };
  try {
    payload = await req.json();
  } catch {
    return new Response("bad json", { status: 400 });
  }

  // Deregistration pings: the athlete revoked momentum inside Garmin Connect — mark the
  // connection so Settings shows "reconnect" instead of silently going stale.
  for (const d of payload.deregistrations ?? []) {
    await supabase.from("vendor_connections")
      .update({ status: "revoked" })
      .eq("vendor", "garmin").eq("vendor_user_id", String(d.userId));
  }

  const activities = payload.activities ?? [];
  if (activities.length === 0) return new Response("ok", { status: 200 });

  // Resolve all pushed userIds → momentum users in one query.
  const userIds = [...new Set(activities.map((a) => String(a.userId)))];
  const { data: conns } = await supabase.from("vendor_connections")
    .select("user_id, vendor_user_id")
    .eq("vendor", "garmin").in("vendor_user_id", userIds);
  const byGarminId = new Map((conns ?? []).map((c) => [c.vendor_user_id, c.user_id]));

  const rows = activities.flatMap((a) => {
    const userId = byGarminId.get(String(a.userId));
    if (!userId || !a.summaryId || a.startTimeInSeconds == null) return []; // unknown/malformed → drop
    return [{
      user_id: userId,
      vendor: "garmin",
      vendor_activity_id: String(a.summaryId),
      activity_type: a.activityType ?? null,
      started_at: new Date(a.startTimeInSeconds * 1000).toISOString(),
      duration_s: a.durationInSeconds ?? 0,
      distance_m: a.distanceInMeters ?? null,
      avg_hr: a.averageHeartRateInBeatsPerMinute ?? null,
      elevation_gain_m: a.totalElevationGainInMeters ?? null,
      summary: a,
    }];
  });

  if (rows.length > 0) {
    // Idempotent on (vendor, vendor_activity_id): Garmin redelivers on any non-200, and manual
    // backfills replay history — repeats update the summary rather than erroring or duplicating.
    const { error } = await supabase.from("vendor_activities")
      .upsert(rows, { onConflict: "vendor,vendor_activity_id", ignoreDuplicates: false });
    if (error) {
      console.error("[garmin-webhook] stage failed", error);
      return new Response("stage failed", { status: 500 }); // non-200 → Garmin retries
    }
    // Staleness indicator for Settings ("last synced …").
    const touched = [...new Set(rows.map((r) => r.user_id))];
    await supabase.from("vendor_connections")
      .update({ last_event_at: new Date().toISOString() })
      .eq("vendor", "garmin").in("user_id", touched);
  }

  return new Response("ok", { status: 200 });
});
