# Onboarding Motion & Conversion Plan
### "The Cal AI of fitness" — make the first 90 seconds feel inevitable

> Scope: the onboarding flow (`Features/Onboarding/*`) and its motion system. Implements the
> direction in the [[onboarding-motion-language]] memory and obeys `CLAUDE.md` + PRD §4.1, §6, §18.
> Authored 2026-06-09 after a research pass on Cal AI / Noom / Opal-class converting onboardings.

---

## 0. Goal & guardrails

**Goal.** Turn onboarding from "a clean questionnaire" into a *cinematic, personalized, high-investment*
experience that (a) feels enterprise-grade in motion and (b) is architected to convert like the
category leaders — without violating momentum's identity.

**Non-negotiable guardrails (these override any pattern below):**
- **Earned iridescence only.** Iridescent accent appears *only* on progress/achievement surfaces
  (the route draw, the progress bar, the reveal ring, a commitment ring, a projection curve). Never
  decorative. Everything else stays ~95% monochrome.
- **Transforms only, 60fps, honor Reduce Motion.** Animate opacity/scale/offset — never layout.
  Every motion has a static/crossfade fallback.
- **Deterministic engine, AI narrates.** Any number we *project* (timeline, weekly volume, "fitter by
  X") comes from `PlanService` / the rules engine — never invented for effect. **No medical claims.**
- **No-shame.** No red "failed"/"behind" framing. Commitment and projection beats are encouraging,
  never coercive.
- **Social is deferred** (PRD). *Trust signals* (ratings, athlete counts, testimonials) are allowed —
  they are not a social graph/feed — but use them sparingly and only if substantiable.

---

## 1. Research synthesis — what actually converts

The leaders (Cal AI ≈28–33 steps → $30M+ ARR, Noom, Opal) converge on one architecture: **a long,
animated, deeply personalized quiz that manufactures investment and ends on a personalized plan + soft
paywall.** The mechanics that move the numbers:

| Lever | Evidence | momentum translation |
|---|---|---|
| **Outcomes > features** | +17% trials, +13% ARPU when reframed to outcomes | Every screen answers "what do *you* get," not "what the app does" |
| **Aha! < 60s** | core-value-in-60s; before/after shown, not described | The welcome route-draw *is* our 5-second demo; reach the personalized plan fast |
| **Deep personalization** | +8.5–27% conversion, +22–35% ARPU; "this is just for me" | Reflect every answer back; live-update previews as they choose |
| **Instant-feedback inputs** | Cal AI's speed slider shows the timeline shift live | Day/session/goal pickers preview the resulting week in real time |
| **Micro-commitments** | checkmarks, hold-to-confirm, "do you relate?" framing, "great choice!" | A hold-to-commit ring; affirmation beats between sections |
| **Personalized plan reveal** | Noom "plan reserved"; the sold moment | We have it — strengthen with a projection curve + celebration |
| **Trust signals on dead time** | loading screens are prime real estate for proof | The "building your plan" beat carries rotating proof lines |
| **Remove loading dead-screens** | −loading screens → +22% trials | Our loaders *do work* (map draws, lines tick) — never a blank spinner |
| **Friction last** | sign-in/permissions moved to the end | Already correct (location primer is last); keep it |
| **Longer trials** | 17–32 day trials convert ~45.7% vs ~26.8% for 3–7 day | If/when a trial ships, bias longer |
| **Microinteraction timing** | 200–300ms, purposeful, haptic-confirmed, native | Matches our `Motion` tokens + `Haptics` |

Sources at the bottom.

---

## 2. Where momentum stands today (gap analysis)

**Already strong:** welcome route-draw + rack-focus dissolve; iridescent progress bar w/ comet cap;
directional step travel; per-element reveal cascade; selection cards (spring + haptic + check spring-in);
the "building your plan" map loader with personalized lines; the reveal (iridescent ring + count-up +
first-week cascade + celebration haptic); location primer framed by benefit.

**Gaps vs. the bar:**
1. **No instant-feedback personalization.** Pickers are static; the user doesn't *see* their choice
   reshape anything until the very end.
2. **No commitment beat.** Nothing converts a passive tapper into an invested one mid-flow.
3. **No projection/transformation moment.** We tell ("Leaner & stronger") but never *show* a trajectory.
4. **Reflections are under-sold.** Answers are echoed only on the reveal, not built up along the way.
5. **The "building" loader wastes trust real estate** — no proof, no per-line completion reward.
6. **Motion vocabulary is ad-hoc**, not a documented system — risks drift as we add screens.
7. **No celebration micro-rewards** between sections ("nice — that's the hard part done").

---

## 3. The motion system (foundation for everything else)

Codify the vocabulary so new screens inherit it instead of reinventing it. (Most lives in
`DesignSystem/Motion.swift` + a small `OnboardingMotion` helper.)

- **Timing scale** (extend `Motion`): `micro` 0.2s (taps/checks), `entrance` 0.45s (reveals),
  `travel` 0.5s spring (step changes), `hero` 1.0–2.6s (route/ring/curve draws).
- **Curves:** entrances `easeOut`; selections `lively` spring (low overshoot, premium not playful);
  hero draws `timingCurve(0.42,0,0.22,1)` (the welcome pen curve — reuse everywhere a line/ring draws).
- **The cascade:** elements assemble bottom-up, ~60ms stagger (have it) — standardize via the existing
  `.reveal(delay:)`.
- **Directional travel:** forward-from-right / back-from-left (shipped) — the spatial spine of the flow.
- **Selection microinteraction standard:** fill morph + checkmark spring-in + selection haptic, ≤250ms.
- **Earned-iridescence surfaces** (the only places the accent may animate): progress bar, route draw,
  commitment ring, projection curve, reveal ring, celebration.
- **Reduce Motion contract:** every beat above maps to a crossfade + static iridescence + immediate
  value. (Already the pattern in `RevealOnAppear`, `IridescentView`, `RouteDrawMap`.)

---

## 4. Flow redesign — screen by screen

Proposed step order (new beats in **bold**), `OnboardingViewModel.Step`:

`coldOpen → disciplines → goal → **relate** → experience → days → equipment? → session →
**preview** → why → **commitment** → calibration → building → reveal → **projection** → primers`

**coldOpen** *(done)* — keep. This is our sub-5s "demo." One polish: a ~0.4s pre-warm hold so the
map's street tiles load before the route draws (avoids the blank-grid first-launch flash).

**disciplines / goal / experience / equipment / why** *(have cards + cascade)* — apply the selection
standard; add a one-line **affirmation flash** after the first pick on a screen ("Nice — that shapes
everything"), 200ms, monochrome, no iridescence.

**`relate` (NEW, micro-commitment).** A "do you relate?" beat after `goal`: 1–2 empathetic statements
tuned to the goal ("Some weeks you run. Some weeks life wins. We plan for both.") with a soft
**"Yeah, that's me"** affirmation. Builds the no-shame, "they get me" frame. Pure type + crossfade.

**days / session (instant-feedback upgrade).** As the user picks, a live preview chip updates beneath:
e.g. 4 days → "≈ 4 sessions · ~3h/week · ~12 mi" — numbers from a lightweight `PlanService` estimate,
animated via `AnimatedCounter`. This is Cal AI's single highest-leverage trick.

**`preview` (NEW, transformation tease).** A compact animated **week strip** assembling from the
current answers (7 day-cells, sessions dropping in with the cascade) — a 3-second "here's your week
forming" before the deep questions finish. Reuses the reveal's session-row styling at small scale.

**`commitment` (NEW, the investment hook).** The Opal "fist-bump" analogue, on-brand: a **hold-to-commit
ring** — press and hold for ~1.2s while the **iridescent ring fills** (earned!) and a haptic ramps;
release on full = "I'm in." Copy: "Commit to keep moving." This is the single biggest conversion
upgrade and is *fully* aligned with our "earned ring" identity. Reduce Motion: a tap-to-commit with
static ring.

**building** *(have map loader)* — upgrade dead time into proof + reward:
- Each personalized line **ticks to a checkmark** as it "completes" (micro-reward loop).
- A thin **iridescent analysis ring** fills 0→100% across the beat (earned progress).
- One rotating **trust line** ("Built on the same rules coaches use" / substantiable proof only).

**reveal** *(strong)* — add a brief **`CompletionCelebration`** trigger on appear (component exists),
and feed the new projection curve below the ring.

**`projection` (NEW, the "sold" payoff).** The hero tie-in: the **same self-drawing iridescent line**
from the welcome, now plotting a **deterministic** projected-progress curve over the next N weeks
(consistency/volume/e1RM trend from `PlanService`). Labeled, honest, no medical claims. This visually
closes the loop: the route you saw at "hello" becomes *your* trajectory at "let's go."

**primers** *(have location)* — add a **notifications primer** framed by benefit ("A nudge on session
days — nothing else"), same orb + reveal. Permission asks stay last (friction-last).

---

## 5. New reusable components

- `HoldToCommitRing` — iridescent ring that fills on long-press, haptic ramp, completion pop. (≈ reuse
  `ProgressRing` + `RestTimerRing` patterns.)
- `LivePreviewChip` — animated stat chip (`AnimatedCounter` + monospaced) for instant-feedback pickers.
- `ProjectionCurve` — Canvas/`MapPolyline`-style self-drawing iridescent line over an axis; data in,
  draw out. (Shares the welcome pen curve + comet head.)
- `AffirmationFlash` / `RelateCard` — lightweight type-only commitment beats.
- `WeekStrip` — compact 7-cell week that assembles via cascade (preview + reveal share it).

---

## 6. Phased execution

| Phase | Scope | Effort | Risk | Converts? |
|---|---|---|---|---|
| **P1 — Motion foundation** | Extend `Motion`; standardize selection + cascade + travel; affirmation flashes; pre-warm map; Reduce-Motion audit | S | Low | Polish/feel |
| **P2 — Instant-feedback personalization** | `LivePreviewChip` on days/session/goal; strengthen running "built around you" reflections; `relate` beat | M | Low–Med | **High** |
| **P3 — Investment + payoff beats** | `HoldToCommitRing` commitment; `building` proof+checkmarks+ring; `ProjectionCurve` + celebration on reveal; `WeekStrip` preview | L | Med | **Highest** |
| **P4 — Monetization scaffold** *(separate track)* | Trial/paywall slot (Superwall/RevenueCat per allowed-deps), "plan reserved" framing, decoy pricing, bias longer trial | M | Med | Direct $ |

Recommended order: **P1 → P3 → P2 → P4.** (P3's commitment + projection are the felt "enterprise"
wow the user is asking for; P2 is the quiet conversion engine; P4 is a deliberate product decision.)

---

## 7. Metrics & A/B hooks (build them in from P1)

Instrument step-level **drop-off**, **time-per-step**, **commitment completion rate**, **reveal→primer
completion**, and (P4) **trial-start / paywall-view**. Gate each new beat behind a flag so it's
A/B-testable — the leaders won by testing relentlessly, not by taste alone.

---

## 8. Principle-compliance checklist (run before each PR)

- [ ] Iridescence only on progress/achievement surfaces
- [ ] Transforms only; 60fps; Reduce-Motion fallback present
- [ ] Projected numbers come from the deterministic engine; no medical claims
- [ ] No red/shame states; copy stays encouraging
- [ ] Trust signals substantiable; no social graph
- [ ] Tabular figures on all live numerals; haptics on commitments

---

## Sources
- Cal AI teardowns — [Mobbin flow](https://mobbin.com/explore/flows/579da5dd-453a-4e7c-9c11-d20708a4db82), [screensdesign](https://screensdesign.com/showcase/cal-ai-calorie-tracker), [Latka ($35M/yr)](https://getlatka.com/blog/how-cal-ai-achieved-35-million-revenue-in-just-one-year/)
- [Adapty — 7 onboarding best practices (with conversion data)](https://adapty.io/blog/how-to-fix-your-onboarding-flow/)
- [DesignerUp — study of 200+ onboarding flows](https://designerup.co/blog/i-studied-the-ux-ui-of-over-200-onboarding-flows-heres-everything-i-learned/)
- [RevenueCat — Noom web-to-app funnel teardown](https://www.revenuecat.com/blog/growth/web-to-app-onboarding-funnel/)
- [Opal onboarding teardown](https://screensdesign.com/showcase/opal-screen-time-control)
- [Apphud — high-converting paywall design](https://apphud.com/blog/design-high-converting-subscription-app-paywalls)
- [UXPin — onboarding microinteractions guide](https://www.uxpin.com/studio/blog/designing-onboarding-microinteractions-guide/)
