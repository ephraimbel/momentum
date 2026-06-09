// Supabase Edge Function: coach-chat (PRD §4.7)
//
// A conversational coach. Given the chat history + a `context` object (the athlete's training
// status, today's plan, recent workouts, streak, and long-term memory), returns ONE short reply
// as STRICT JSON. The iOS app authenticates with the Supabase user JWT and falls back to the
// deterministic CoachResponder.swift whenever this is slow/down/unconfigured — so the chat never
// blocks.
//
// Deploy:  supabase functions deploy coach-chat
// Secrets: supabase secrets set ANTHROPIC_API_KEY=... AI_MODEL=claude-opus-4-8 AI_MAX_TOKENS=350
//
// Model note: AI_MODEL defaults to claude-opus-4-8. Opus 4.8 REMOVES `temperature`/`top_p`/`top_k`
// (sending them 400s), so we don't set them — output shape is constrained via structured outputs.

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";

const MODEL = Deno.env.get("AI_MODEL") ?? "claude-opus-4-8";
const MAX_TOKENS = Number(Deno.env.get("AI_MAX_TOKENS") ?? "350");

const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

const SYSTEM = `You are momentum's coach, in a chat with this athlete. You're given the recent \
conversation and a \`context\` object: their training status (acute:chronic load ratio and what it \
means), today's planned session if any, recent workouts, current streak, goal, and your long-term \
\`memory\` (facts you've derived + notes you believe; honor any note with \`pinned: true\` as ground \
truth).

Reply in ONE short, warm, specific message (<= 60 words), second person. Ground every claim in the \
numbers from \`context\` — never invent data. The plan engine owns loads/paces/volumes; you narrate \
and advise within them, you do not compute new numbers. Be a no-shame coach: a missed or partial \
session just moves on. Never give medical or injury diagnosis. If asked to do something outside \
training, gently steer back.

Output STRICT JSON matching the schema.`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    reply: { type: "string" },
    // Optional structured suggestion the app can render as a tappable action.
    action: {
      type: "object",
      additionalProperties: false,
      properties: {
        kind: { type: "string", enum: ["none", "startToday", "adjustPlan", "viewProgress"] },
        label: { type: "string" },
      },
      required: ["kind", "label"],
    },
  },
  required: ["reply", "action"],
};

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    // { messages: [{role:"user"|"assistant", text}], context: {...} }
    const payload = await req.json();
    const history = (payload.messages ?? []).map((m: { role: string; text: string }) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: m.text,
    }));
    const message = await client.messages.create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: SYSTEM + "\n\nCONTEXT:\n" + JSON.stringify(payload.context ?? {}),
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: history.length ? history : [{ role: "user", content: "Hello" }],
    });
    const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
    return json(JSON.parse(text), 200);
  } catch (_e) {
    // The client renders its deterministic CoachResponder on any non-200 — never block.
    return json({ error: "coach_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
