# Momentum — App Store Connect metadata & ASO

> Copy‑paste‑ready App Store listing, optimized to rank alongside Runna, Strava, Nike Run Club and
> the running‑app cohort in **Health & Fitness**. Character limits are Apple's hard caps.
> ⚠️ **Name vetting:** "Momentum" is used by other apps (habit trackers, a browser). Before submission,
> confirm the exact **App Name is available** on the App Store and clears trademark — otherwise fall back
> to a distinct display name (e.g. "Momentum Run"). This is the one open blocker for the listing.

## Core fields

**App Name** (30 chars) — brand + top keywords, mirroring Runna's "Running Training Plans":
```
Momentum: Run Training Plans
```
*(28 chars. Apple indexes every word, so "run", "training", "plans" are covered — don't repeat them in Keywords. Alt: `Momentum: Running Trainer` (25).)*

**Subtitle** (30 chars) — the differentiator, keyword‑dense:
```
Adaptive coach, 5K to marathon
```
*(30 chars. "adaptive/coach/5K/marathon" all index. Alt: `Marathon & 5K plans that adapt`.)*

**Keywords** (100 chars, comma‑separated, NO spaces, singular, no words already in Name/Subtitle):
```
tracker,hrv,route,couch,half,10k,ultra,pace,vo2,trail,interval,strength,recovery,workout,race,gps
```
*(97 chars — LIVE in ASC as of 2026-07-16. Repositioning swaps: `club` REMOVED with the social layer
("run club" searches now land on a promise the app doesn't make) → `hrv` (the Bevel/Whoop-audience
term); `tempo` REMOVED (nobody types "tempo" into App Store search) → `trail` ("trail running" is a
top Strava-side search we support). Coverage the combos form (Apple indexes Name+Subtitle+Keywords):
Runna-side — running training plan / marathon training plan / half marathon training / couch to 5k /
running coach / 5k·10k training / race training / interval training; Strava-side — run tracker /
gps running / running route / trail running; Bevel-side — hrv / recovery / vo2. Do NOT put
"Strava"/"Runna"/"Bevel"/competitor trademarks here — Apple rejects competitor marks.)*

**Promotional Text** (170 chars, updatable anytime without review):
```
Plans built by runners, for runners. Momentum reads your recovery and builds your training around it: adaptive race plans, honest goal verdicts, injury protection.
```
*(162 chars — repositioned 2026-07-29 per owner: runner-built leads, never "AI plan"; no dash next
to the runner phrase (owner voice call 2026-07-30, dashes read as AI-written). Promotional text is
NOT search-indexed, so it carries the conversion phrase; the Subtitle stays keyword-dense. NOT yet
pushed to the live listing — the API write needs the owner's go-ahead (permission-gated).)*

**Primary category:** Health & Fitness · **Secondary:** Sports

## Description (≤4000 chars)
> Repositioned 2026-07-16: **solo endurance coach** — no social/community anywhere in the listing.
> Positioning: Bevel-style health-informed training + Runna-style catered plans, for endurance athletes.
> **LIVE in ASC as of 2026-07-16** (saved on the 1.0 version page). ⚠️ ASC rejects `──` box-drawing
> characters ("invalid characters" on save) — section headers are plain caps; `•` bullets are fine.
```
Momentum is your personal endurance coach. It builds a training plan around your body, your schedule, and your race, then adapts it week by week from how you're actually recovering.

Most running apps hand you a rigid plan and hope for the best. Momentum reads your sleep, resting heart rate and HRV, watches your training load, and adjusts before you break down. No hype. No shame. Just steady progress, from your first 5K to your first ultra.

A PLAN BUILT FOR YOU
• A personalized training plan for your race: 5K, 10K, half, marathon, or ultra
• Paces set from your real fitness, not a generic table, and recalibrated every time you get faster
• Race day is on your calendar, with a taper that follows the science and a recovery block after
• Honest verdicts: an on-track or at-risk read on your goal, early enough to act on it

YOUR HEALTH DECIDES YOUR TRAINING
• Readiness from your sleep, resting heart rate and HRV, straight from Apple Health
• A rough night eases today's session; a rising training load eases your week
• Injury-smart: flags risky load spikes before they hurt, and guides a careful return when something flares
• Recovery is part of the plan, not an afterthought

GUIDED RUNS, REAL COACHING
• Structured workouts with live pace and heart-rate zones: tempo, intervals, race-pace long runs
• A post-run breakdown that actually teaches: splits, pace, HR and elevation, in plain language
• Race-week briefing, fueling guidance, and a shakeout the day before

STRENGTH FOR ENDURANCE
• Short, runner-specific strength sessions that build durability and cut injury risk
• See exactly which muscles you worked, session to session

BUILT FOR APPLE, BUILT FOR YOU
• Native, beautiful, fast, and private: your training data is yours
• Deep Apple Health integration (Apple Watch, Garmin, Oura, Whoop all flow in through Health)
• Works offline. Every run and set is saved the moment it happens

Momentum keeps you moving: fitness you can trust, without the burnout.

Fueling guidance, never dieting. Coaching, never a diagnosis.

Terms of Use (EULA): https://momentumco.app/terms
Privacy Policy: https://momentumco.app/privacy
```
> **Legal links added 2026-07-22 for guideline 3.1.2(c)** — an auto-renewable-subscription app must
> expose a functional Terms of Use (EULA) link in the App Store metadata. The two lines above go at
> the END of the live ASC description (both URLs verified live). Belt-and-suspenders, ALSO set the
> custom EULA in ASC (see the remediation runbook below). The app itself already shows both links in
> the paywall fine-print and Settings, and the subscription title/length/price/renewal terms on the
> paywall — the miss was metadata-only.

## What's New (first release)
```
The first Momentum: your adaptive running coach. Build a plan for your race, train with live pace and heart-rate guidance, and get an honest read on your goal — with recovery and injury protection built in.
```

## Privacy nutrition label (App Store Connect → App Privacy)
Declare accurately (you collect these):
- **Location** — precise, for tracking runs (linked to the user, used for App Functionality; not for tracking/ads).
- **Health & Fitness** — workouts, heart rate, HRV, sleep (via HealthKit; App Functionality; not shared).
- **Identifiers** — account id for the owner-only cloud backup (Supabase auth). *(Social layer removed
  2026-07-16: no posts/comments/feed. If "User Content" was declared for the social layer, it can be
  trimmed to just workout photos/notes the user attaches to their own private workouts.)*
- **Purchases** — subscription status (RevenueCat/Superwall). Not linked to identity for tracking.
- HealthKit data is **never** used for advertising and must not leave the device except to the user's own account.

## Pricing (subscriptions — App Store Connect → Subscriptions)
Two auto-renewing subscriptions in one group (must match `PaywallOffering.standard` in the app):
- **momentum Pro — Monthly** (`momentum_pro_monthly`): **$9.99/mo**, no trial — the trial is the annual's nudge (owner call 2026-07-30). (Repriced 2026-07-29 — mass-market positioning; the hard paywall makes price the conversion funnel.)
- **momentum Pro — Annual** (`momentum_pro_annual`): **$59.99/yr** (under $5/mo — half Runna's annual, below Strava's $79.99; the savings badge reads a clean "save 50%"), **7-day free trial**.

The App Store renders these prices natively from the product — the listing **description does not hardcode them**. Full activation runbook: `docs/MONETIZATION-SETUP.md`.

## App Store Connect setup checklist (your actions — needs your Apple account)
1. **Apple Developer Program** membership active; sign in to App Store Connect.
2. **Register the App ID** `com.ephraimbel.momentum.app` (+ `.widgets`, `.watchkitapp`) with the needed capabilities
   (HealthKit, Location, App Groups, Push if used).
3. In `project.yml`, set `DEVELOPMENT_TEAM` to your Team ID (currently empty), then `xcodegen generate`.
4. Bump `MARKETING_VERSION` → `1.0.0` for a public release (0.1.0 is fine for TestFlight beta first).
5. **Create the app record** in App Store Connect (pick the name above once availability is confirmed).
6. In Xcode: **Product → Archive** (Release) → distribution signing → **upload** via Organizer (or Transporter).
7. Attach this metadata, screenshots (6.7"/6.9" + iPad if supported), and the privacy label; submit to TestFlight, then App Review.

## App Review rejection remediation — 2026-07-22 (three issues, one resubmission)

A rejection cited 5.6.3, 2.1(b) and 3.1.2(c). One is code (done); two are your App Store Connect
actions. Do all three, then upload the new build (bump `CURRENT_PROJECT_VERSION` — builds 1–3 are
used) and reply to the reviewer with the screen recording noted below.

### 1 — Guideline 5.6.3 (rating during onboarding) — FIXED IN CODE ✅
The rating ask was the last beat of onboarding. It's gone. The native prompt now fires only from the
**finished-workout moment**, after the athlete has SAVED three workouts through the app (`AppReview` +
`WorkoutRunner.dismissSummary`) — never on first launch, never in onboarding, once ever. Ships in the
new build; no ASC action.

### 2 — Guideline 2.1(b) (In-App Purchases not submitted) — YOUR ASC ACTION
The subscriptions exist but weren't submitted for review. In App Store Connect:
1. **Subscriptions** → the `Momentum Pro` group → each product (`momentum_pro_monthly`,
   `momentum_pro_annual`): status must be **Ready to Submit**. Fill anything missing (localized
   display name, description, **subscription duration**, price).
2. Add the **App Review screenshot** each subscription requires (a screenshot of your paywall showing
   that product — `--seed-demo --debug-free --paywall` gives you a clean one). *Without this screenshot
   the IAP cannot be submitted — this is the specific blocker Apple named.*
3. On the **version** page (1.0), scroll to **In-App Purchases and Subscriptions** and **attach both
   products to this version** so they submit together with the build.
4. Submit the version — the IAPs go to review with it.

### 3 — Guideline 3.1.2(c) (subscription metadata — Terms of Use) — YOUR ASC ACTION
The app already shows title/length/price/renewal-terms + functional Privacy and Terms links on the
paywall (both URLs verified live). The miss is ASC metadata:
1. **App Description** — the two legal-link lines are now appended to the description in this doc;
   paste them onto the end of the live description on the 1.0 version page.
2. **App Information → License Agreement (EULA)**: replace Apple's standard EULA with your **custom**
   EULA. Either paste the text of `https://momentumco.app/terms`, or (simpler) keep the description
   link — Apple accepts "App Description **or** EULA field." Doing both is safest.
3. **App Privacy → Privacy Policy URL**: confirm it is set to `https://momentumco.app/privacy`.

### Reviewer reply
Apple asked for confirmation. After the above, reply in Resolution Center with a **screen recording**
that shows, in one pass: opening the paywall → the subscription **title, length ("/ year", "/ month"),
price**, and **renewal terms** are visible → tapping **Terms** and **Privacy** opens working pages.
Add the same note to **App Review Information → Notes** for future submissions.

---

## ASO strategy notes (repositioned 2026-07-16 — SOLO app, no social)
- **The lane:** "Bevel for endurance athletes" — health/recovery data decides the training — crossed
  with Runna-grade catered race plans. NOT a social app: no feed, no club, no community anywhere in
  copy, keywords, or screenshots (saying otherwise invites App Review scrutiny of features we removed).
- **Rank next to Runna/Bevel/Whoop-adjacent searches** by owning the shared terms (marathon, training
  plan, pace, 5K/10K/half, VO₂, hrv, recovery, intervals) + Health & Fitness category — never naming them.
- The **differentiators**: *your health decides your training* (readiness eases sessions), *honest goal
  verdicts*, *race day on the calendar with recovery block after*, *strength-for-endurance* — what
  Runna (rigid plans) and pure trackers (no coaching) don't do.
- **Screenshots** must contain NO community/feed/social frames: lead with the adaptive plan, readiness
  easing a session, a guided run with live pace/HR, the honest post-run read, the lit-up strength body.
- Iterate **Keywords + Subtitle** post-launch using App Store Connect's search-term impressions.
```
