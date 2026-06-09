// Supabase Edge Function: plan-narrate (PRD §8.8)
//
// Takes the DETERMINISTIC adaptation result (computed by the rules-based PlanEngine, §9) and writes
// a one-line human rationale. The LLM never computes loads/volume/paces — only narrates.
//
// Deploy:  supabase functions deploy plan-narrate
// Secrets: shared with workout-analysis (ANTHROPIC_API_KEY, AI_MODEL).

import Anthropic from "npm:@anthropic-ai/sdk@^0.69";

const MODEL = Deno.env.get("AI_MODEL") ?? "claude-opus-4-8";
const client = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

const SYSTEM = `You are momentum's coach. Given a deterministic plan adjustment (what changed and \
why, already decided by rules), write a single warm rationale of <= 16 words, second person, no \
shame, no medical claims. Output STRICT JSON: {"rationale": "..."}.`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: { rationale: { type: "string" } },
  required: ["rationale"],
};

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json();
    const message = await client.messages.create({
      model: MODEL,
      max_tokens: 120,
      system: SYSTEM,
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content: JSON.stringify(payload) }],
    });
    const text = message.content.find((b) => b.type === "text")?.text ?? "{}";
    return json(JSON.parse(text), 200);
  } catch (_e) {
    return json({ error: "narration_unavailable" }, 503);
  }
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
