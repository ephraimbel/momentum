# momentum — Supabase Edge Functions

Server-side AI for momentum (PRD §8.8). The deterministic plan engine (§9) runs **on-device**;
these functions only author *narrative text*, never loads/volumes/paces. (The `garmin-*` pair is
the exception: not AI — the direct-wearable connect/ingest plumbing, docs/WEARABLES-DIRECT.md.)

| Function | Purpose |
|---|---|
| `workout-analysis` | Post-workout AI read (≤55 words, strict JSON, plan-aware). |
| `plan-narrate` | One-line rationale (≤16 words) for a deterministic plan adjustment. |
| `garmin-oauth` | Garmin connect flow (OAuth2+PKCE `/start` + `/callback`). Deploy `--no-verify-jwt` — `/start` verifies the user JWT itself. |
| `garmin-webhook` | Garmin activity-push receiver → `vendor_activities` staging inbox (idempotent). Deploy `--no-verify-jwt`. |

## Reliability contract (do not break)
The iOS app **always** has a deterministic template fallback (`WorkoutReadTemplates.swift`,
`PlanCoaching.brief`). If a function is slow (>4s), down, or undeployed, the app renders the
template instantly. These functions are an *enhancement*, never a dependency of the moment.

## Deploy
```bash
supabase functions deploy workout-analysis
supabase functions deploy plan-narrate
supabase secrets set GEMINI_API_KEY=AIza...   # shared by coach-chat / workout-analysis / plan-narrate / meal-estimate
# optional: AI_MODEL=gemini-flash-latest  AI_MAX_TOKENS=800
```

## Notes
- **Model (2026-07-16):** every function runs **Gemini Flash** via the `gemini-flash-latest` rolling
  alias (`gemini-2.5-flash` is sunset for new keys). Current Flash THINKS by default and bills the
  thought tokens against `maxOutputTokens` — thinking is pinned to its `"low"` floor and each cap
  carries headroom, thought parts (`thought: true`) are filtered out of replies, and structured
  output rides `responseJsonSchema` (standard JSON Schema; the OpenAPI-dialect `responseSchema` is
  2.5-only). meal-estimate keeps a legacy Anthropic *fallback* path that goes quiet without its key.
- **Auth:** invoked with the Supabase user JWT; deploy with JWT verification on.
- **Rate limit:** enforce ~60/user/day at the edge or via a Postgres counter (§8.8).
- **Status:** committed for Phase 4 deploy. `AIService.swift` currently returns the template; wire
  the live POST there once these are deployed and keys are set.
