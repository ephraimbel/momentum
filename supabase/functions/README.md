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
supabase secrets set ANTHROPIC_API_KEY=sk-ant-... AI_MODEL=claude-opus-4-8 AI_MAX_TOKENS=400
```

## Notes
- **Model:** `claude-opus-4-8` (default). Opus 4.8 removes `temperature`/`top_p`/`top_k` (sending
  them 400s), so output shape is constrained via **structured outputs** (`output_config.format`),
  not sampling params. The PRD's `temperature=0.4` predates the 4.8 API and is intentionally omitted.
- **Auth:** invoked with the Supabase user JWT; deploy with JWT verification on.
- **Rate limit:** enforce ~60/user/day at the edge or via a Postgres counter (§8.8).
- **Status:** committed for Phase 4 deploy. `AIService.swift` currently returns the template; wire
  the live POST there once these are deployed and keys are set.
