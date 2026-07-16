// Supabase Edge Function: plan-narrate (PRD §8.8)
//
// Takes the DETERMINISTIC adaptation result (computed by the rules-based PlanEngine, §9) and writes
// a one-line human rationale. The LLM never computes loads/volume/paces — only narrates.
//
// Deploy:  supabase functions deploy plan-narrate
// Secrets: shared with workout-analysis / coach-chat (GEMINI_API_KEY, optional AI_MODEL).
//
// Model note (2026-07-16, user call): Gemini Flash via the `gemini-flash-latest` rolling alias.
// Thinking pinned to its "low" floor (thought tokens bill against maxOutputTokens); thought parts
// filtered; structured output via `responseJsonSchema`.

const MODEL = Deno.env.get("AI_MODEL") ?? "gemini-flash-latest";
const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? Deno.env.get("GOOGLE_API_KEY") ?? "";
// A ≤16-word rationale is ~30 tokens; the rest is headroom for thinking, which bills against this
// cap even at the "low" floor — 400 came back as an empty object, thought tokens having eaten it.
const MAX_TOKENS = Number(Deno.env.get("AI_MAX_TOKENS") ?? "1024");

const SYSTEM = `You are momentum's coach. Given a deterministic plan adjustment (what changed and \
why, already decided by rules), write a single warm rationale of <= 16 words, second person, no \
shame, no medical claims. Output STRICT JSON: {"rationale": "..."}.`;

const SCHEMA = {
  type: "object",
  properties: { rationale: { type: "string" } },
  required: ["rationale"],
};

/// Non-thought text parts of a GenerateContentResponse, concatenated.
// deno-lint-ignore no-explicit-any
function replyText(data: any): string {
  const parts = data?.candidates?.[0]?.content?.parts ?? [];
  // deno-lint-ignore no-explicit-any
  return parts.filter((p: any) => typeof p?.text === "string" && !p.thought)
    // deno-lint-ignore no-explicit-any
    .map((p: any) => p.text).join("") || "{}";
}

/// Prose-tolerant JSON: take the outermost {...} block, whatever the model wrapped it in.
function parseJSON(text: string): unknown {
  const first = text.indexOf("{"), last = text.lastIndexOf("}");
  if (first < 0 || last <= first) throw new Error("no_json");
  return JSON.parse(text.slice(first, last + 1));
}

Deno.serve(async (req) => {
  if (!req.headers.get("authorization")) {
    return json({ error: "unauthorized" }, 401);
  }
  try {
    const payload = await req.json();
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
      {
        method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: SYSTEM }] },
          contents: [{ role: "user", parts: [{ text: JSON.stringify(payload) }] }],
          generationConfig: {
            maxOutputTokens: MAX_TOKENS,
            thinkingConfig: { thinkingLevel: "low" },
            responseMimeType: "application/json",
            responseJsonSchema: SCHEMA,
          },
        }),
      },
    );
    if (!res.ok) throw new Error(`gemini_${res.status}`);
    return json(parseJSON(replyText(await res.json())), 200);
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
