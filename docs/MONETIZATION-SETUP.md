# Monetization setup — activating RevenueCat + Superwall

Phase 3 ships the **gating + paywall + entitlement** layer fully working on a local seam
(`PaywallController`). Billing runs through **RevenueCat** (entitlement `pro`, offering `default`)
and paywall A/B through **Superwall** the moment the SDKs are linked and keys are set — the
integration code is already written behind `#if canImport(RevenueCat)` / `#if canImport(SuperwallKit)`,
so it's inert until then and the app keeps building/testing without it.

> Why this is a separate step: it needs the SPM packages (network), real **App Store Connect**
> products, **RevenueCat/Superwall API keys**, and a **device/sandbox account** to test — none of
> which exist in CI/the build sandbox. Everything below is a one-time activation.

## 1. App Store Connect — products
The products live in ONE subscription group (`22239084 "momentum pro"`) and must share a
`groupLevel` — peers crossgrade at the next renewal, while different levels make a switch an
*upgrade* and trigger a prorated refund of the unused year.

| Product ID | Duration | Price | Intro offer | Sold? |
|---|---|---|---|---|
| `momentum_pro_monthly` | 1 month | **$14.99** | — | yes — the entry plan (2026-09-07; was sold at $9.99 until 2026-08-28, existing monthly subscribers keep that price) |
| `momentum_pro_weekly` | 1 week  | $5.99  | — | **no** — retired from the offering 2026-09-07; stays on sale in ASC so existing weekly subscribers renew |
| `momentum_pro_annual` | 1 year  | **$79.99** | **3 days free** | yes — $6.67/mo, badge "SAVE 55%"; eligible badge "3 DAYS FREE" |
| `momentum_pro_monthly`| 1 month | $9.99  | — | **no** — retired from the offering 2026-08-28 |

The monthly stays live but unsold: removing a product never cancels or re-prices an existing
subscriber, and keeping it is what lets the remaining monthly subs renew. The annual carries a
three-day introductory free trial (restored 2026-09-01 at seven days, cut to three 2026-09-05); weekly
and retired monthly charge immediately. The app reads StoreKit's offer, so only eligible customers
see trial copy and ineligible customers see the ordinary annual purchase terms.

⚠️ **Price decreases flow to existing subscribers automatically at their next renewal** — the
"preserve price" option only exists for increases. The 2026-08-28 cut from $64.99 to $29.99
therefore re-prices every current annual subscriber, including the $59.99 cohort preserved
earlier that month.

**2026-09-05 — annual RAISED $29.99 → $99.99 (owner call).** Scheduled via the API (`POST /v1/subscriptionPrices`
with `preserveCurrentPrice: true`, start 2026-09-06, the earliest date accepted) for the USA point
(`customerPrice 99.99`, proceeds $70.00 first-year) plus its 174 equalizations — 175 rows verified, 175 existing
rows preserved, so every current subscriber keeps what they pay today and only new subscriptions bill $99.99.
Nothing changes in RevenueCat (prices come from StoreKit by product id). In the app the yearly card leads with
**$1.92 / wk**, carries "$99.99 billed yearly", and its badge derives to **SAVE 70%** (67.9% real, nearest-5 rule).

**2026-09-05 — annual trial CUT 7 → 3 days (owner call, same day).** Intro offers cannot be edited: all 175
`ONE_WEEK` FREE_TRIAL offers were DELETEd and 175 `THREE_DAYS` FREE_TRIAL offers POSTed (`/v1/subscriptionIntroductoryOffers`,
relationships subscription + territory, no price point for a free trial), effective 2026-09-05, verified 175/175.
Athletes already inside a 7-day trial keep it. The app derives every trial string from the store's intro offer
(`trialDays(of:)` converts `.day` units directly), the placeholder is `trialDays: 3`, and the "ends in 2 days" reminder
still fires (on day 1) because `scheduleTrialReminder` only skips trials of 2 days or fewer.

**2026-09-05 (later) — annual SETTLED at $79.99 (owner call; the $99.99 change above never took effect).** The 175 pending
$99.99 rows dated 2026-09-06 were DELETEd via `DELETE /v1/subscriptionPrices/{id}` and $79.99 (USA proceeds $56.00 first-year)
plus its 174 equalizations scheduled for 2026-09-06 with `preserveCurrentPrice: true` — existing subscribers stay at what they
pay today. In the app: **$6.67 / mo**, "$79.99 billed yearly", badge **SAVE 55%** (55.5% real against 12 × $14.99).

These IDs must match `PaywallOffering.standard` in `PaywallController.swift`.

## 2. RevenueCat dashboard
- Create the project; add the App Store Connect app + shared secret.
- Entitlement: **`pro`**. Attach both products to it.
- Offering: **`default`** with a **monthly** and an **annual** package (`$rc_monthly` / `$rc_annual`; the `$rc_weekly` package was dropped 2026-09-07). Until the dashboard lists `$rc_monthly`, `loadOffering()` fetches `momentum_pro_monthly` by id and purchases it as a bare store product — the entitlement mapping in RevenueCat is what grants Pro either way. `loadOffering()` returns early unless BOTH resolve, so a missing package silently leaves the app on placeholder prices.
- Copy the **public SDK API key** (App-specific, `appl_…`).

## 3. Superwall dashboard
- Create the app; copy the **public API key** (`pk_…`).
- Create paywalls and assign them to the placements the app already fires:
  `onboarding_complete`, `ai_read`, `full_plan`, `analytics_locked`, `history_locked`
  (see `Feature.placement`). Gate each on the `pro` entitlement (RevenueCat integration in Superwall).

## 4. Wire the project
In `project.yml`:
1. Uncomment the top-level **`packages:`** block (RevenueCat + Superwall).
2. Uncomment the two `- package:` lines under the **Momentum** target's `dependencies`.
3. Set the keys (don't commit real keys — prefer an xcconfig / CI secret over literals):
   ```
   RevenueCatAPIKey: "appl_xxx"
   SuperwallAPIKey:  "pk_xxx"
   ```
Then:
```
xcodegen generate
xcodebuild -scheme Momentum -destination 'generic/platform=iOS' build
```
`PaywallController.configure()` (already called from `MomentumApp.init`) will configure both SDKs,
load live localized prices into the paywall, and keep `isPro` in sync via `customerInfoStream`.

## 5. Verify on device (Gate 3)
- Fresh sandbox account → annual shows **3 days free** with real localized renewal terms; weekly has no trial.
- Purchase → entitlement flips; gated surfaces unlock; **Restore** works on a fresh install.
- **Settings → Manage subscription** opens the App Store sheet (cancel in ≤2 taps).
- Superwall A/B: confirm each placement shows its remote paywall; the native `PaywallView` remains
  the fallback if a placement has no remote paywall.

## What's already done (no action needed)
- `Feature` gating set + Superwall placement mapping (`Feature.placement`).
- `PaywallController` (entitlement, purchase/restore/offerings/listener — all guarded for RevenueCat).
- `PaywallView` (offer screen), `ProLock` (contextual gates), `SettingsView` (status/manage/restore),
  onboarding paywall after the plan reveal.
- Until activation, `--seed-demo` grants Pro (demos/UI-tests) and `--debug-free` forces the free tier.
