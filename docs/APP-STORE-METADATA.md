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
half,10k,pace,jog,ultra,couch,vo2,tempo,interval,cadence,fitness,race,runner,strength,recovery,workout,hr
```
*(~99 chars. Do NOT put "Strava"/"Runna"/competitor trademarks here — Apple rejects competitor marks and it's infringement. You still surface next to them by sharing the generic running keywords + category.)*

**Promotional Text** (170 chars, updatable anytime without review):
```
Train smarter, not just harder. Momentum builds a plan that adapts to your recovery, guards against injury, and tells you the honest truth about your goal.
```

**Primary category:** Health & Fitness · **Secondary:** Sports

## Description (≤4000 chars)
```
Momentum is a running coach that adapts to YOU — from your first 5K to your first marathon.

Most running apps hand you a rigid plan and hope for the best. Momentum is different: it watches how you're actually recovering, adjusts before you break down, and tells you the honest truth about whether your goal is on track. No hype. No shame. Just steady progress.

── A PLAN THAT ADAPTS ──
• A personalized training plan for your race — 5K, 10K, half, marathon, or your first ultra
• Recovery-aware: reads your sleep, resting heart rate and HRV from Apple Health and eases the week when you need it
• Injury-smart: flags rising load before it hurts, and guides a gated return when something flares
• Honest verdicts: an on-track / at-risk read on your goal date — the truth, early enough to act on it

── GUIDED RUNS, REAL COACHING ──
• Structured workouts — tempo, intervals, long runs — with live pace and heart-rate zones
• A post-run breakdown that actually teaches: splits, pace, HR and elevation, with a plain-language read
• Personalized paces and zones from your real fitness (VO₂ estimate + resting-HR), not a generic table

── STRENGTH FOR RUNNERS ──
• Short, run-specific strength sessions that reduce injury and build durability
• See exactly which muscles you worked, session to session

── HONEST, PRIVATE SOCIAL ──
• An opt-in community that celebrates showing up — no vanity metrics, no algorithmic feed
• Private by default. Your data is yours.

── BUILT FOR APPLE ──
• Native, beautiful, and fast — designed for iOS
• Deep Apple Health integration (Apple Watch, Garmin, Oura, Whoop all flow in through Health)
• Works offline — every run and set is saved the moment it happens

Momentum keeps you moving — building fitness you can trust, without the burnout.

Fueling guidance, never dieting. Coaching, never a diagnosis.
```

## What's New (first release)
```
The first Momentum: your adaptive running coach. Build a plan for your race, train with live pace and heart-rate guidance, and get an honest read on your goal — with recovery and injury protection built in.
```

## Privacy nutrition label (App Store Connect → App Privacy)
Declare accurately (you collect these):
- **Location** — precise, for tracking runs (linked to the user, used for App Functionality; not for tracking/ads).
- **Health & Fitness** — workouts, heart rate, HRV, sleep (via HealthKit; App Functionality; not shared).
- **Identifiers / User Content** — if the social layer stores profile + posts (owner-only RLS).
- **Purchases** — subscription status (RevenueCat/Superwall). Not linked to identity for tracking.
- HealthKit data is **never** used for advertising and must not leave the device except to the user's own account.

## App Store Connect setup checklist (your actions — needs your Apple account)
1. **Apple Developer Program** membership active; sign in to App Store Connect.
2. **Register the App ID** `com.momentum.app` (+ `.widgets`, `.watchkitapp`) with the needed capabilities
   (HealthKit, Location, App Groups, Push if used).
3. In `project.yml`, set `DEVELOPMENT_TEAM` to your Team ID (currently empty), then `xcodegen generate`.
4. Bump `MARKETING_VERSION` → `1.0.0` for a public release (0.1.0 is fine for TestFlight beta first).
5. **Create the app record** in App Store Connect (pick the name above once availability is confirmed).
6. In Xcode: **Product → Archive** (Release) → distribution signing → **upload** via Organizer (or Transporter).
7. Attach this metadata, screenshots (6.7"/6.9" + iPad if supported), and the privacy label; submit to TestFlight, then App Review.

## ASO strategy notes
- **Rank next to Runna/Strava** by owning the shared high-volume terms (marathon, training plan, pace,
  5K/10K/half, VO₂, intervals) + Health & Fitness category — not by naming them.
- The **differentiators** to lean on in copy/screenshots: *adaptive/recovery-aware*, *injury-safe*,
  *honest goal verdict*, *strength-for-runners* — these are what Runna (rigid plans) and Strava
  (tracking/social, no coaching) don't do.
- **Screenshots** should lead with the payoff: the adaptive plan, a guided run with live pace/HR, the
  honest post-run read, and the lit-up strength body. First 2 shots matter most for conversion.
- Iterate **Keywords + Subtitle** post-launch using App Store Connect's search-term impressions.
```
