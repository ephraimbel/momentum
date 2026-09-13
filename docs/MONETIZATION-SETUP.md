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
| `momentum_pro_weekly` | 1 week  | **$5.99** (since 2026-08-29) | — | yes — the entry plan again (owner call 2026-09-13) |
| `momentum_pro_annual` | 1 year | **$29.99** (since 2026-09-13) | **7 days free** (since 2026-09-13) | yes — sold at its own per-week number, **$0.58/wk**, badge **SAVE 90%** (90.4% under 52 × $5.99); eligible athletes see "7 DAYS FREE" instead |
| `momentum_pro_monthly` | 1 month | $9.99 (since 2026-09-13) | — | **no** — retired from the offering 2026-09-13; stays on sale in ASC so existing monthly subscribers renew |

**2026-09-13 (current) — weekly back as the entry plan at $5.99; the yearly is displayed per week.**
Owner call: a weekly sticker reads cheaper at the moment of choice, and the yearly shown as "$0.58 a week"
reads cheaper still. The day went $3.99 → $5.99: a $5.99 → $3.99 decrease was scheduled via the API for
09-14 (175 rows), then, on the reasoning that the weekly's job is to anchor the yearly (a 10× gap, SAVE 90%)
and to net more from impulse buyers, all 175 scheduled rows were **DELETEd** the same day
(`DELETE /v1/subscriptionPrices/{id}` → 204 — a scheduled DECREASE is deletable via the API, unlike the
increase that 409'd on 09-05). Read back: 175 current $5.99 rows, nothing pending. The annual ($29.99,
7-day trial) and the monthly ($9.99) were left exactly as configured on 2026-09-11. RevenueCat's `default`
offering still serves `$rc_weekly` / `$rc_annual` / `$rc_monthly` (verified against the public offerings
endpoint), so `loadOffering()` resolves the weekly from the offering and needs no dashboard edit. In the
app, `PaywallOffering.weeklyPrice = 5.99` / `annualPrice = 29.99` are the single source; the yearly card
leads with **$0.58 / wk** and carries "$29.99 billed yearly" (App Review 3.1.2: price and duration
together). Rule that still holds: **$5.99 a week is $26 a month** — the weekly is an anchor and an entry,
never a plan to keep people on; if the weekly is ever cut the yearly must NOT follow the percentage down.
Ships with **1.9.0** (owner call: no interim build); until then the live 1.7.0 already sells this exact pair.
Production reads the actual localized price and eligible introductory offer from StoreKit through
RevenueCat, so it continues showing the current offer until Apple's scheduled transition.

**2026-09-11 (final) — annual reduced to $29.99, effective September 13.** The owner
replaced the previously scheduled $39.99 annual offer with $29.99 on the same product, retaining
the seven-day trial and the $9.99 monthly option. Only the 175 known September 13 annual price
rows were deleted/recreated using the USA $29.99 point and Apple's 174 equalizations. Read-back
at **2026-09-11 22:21 UTC** verified **175/175** replacement annual prices, **175/175** unchanged
seven-day trial offers, **350/350** unchanged live/preserved annual price rows, and unchanged
monthly prices/offers. The build passed, and all **21 billing/paywall tests passed** with zero
failures/skips. Preview/default prices and UI assertions now use $29.99/year ($2.50/mo equivalent),
with savings still calculated from actual store prices. Evidence:
`/tmp/momentum-annual-2999/verification.json` and `/tmp/momentum-annual-2999-tests.xcresult`.
This is the final schedule; earlier entries below describe superseded decisions.

**2026-09-11 (later) — monthly reduced to $9.99, effective September 13.** The existing
`momentum_pro_monthly` product uses its USA $9.99 price point and Apple's 174 equalizations.
Read-back verification at **2026-09-11 22:10 UTC** confirmed **175/175** scheduled monthly prices,
**175/175** unchanged preserved monthly price rows, no monthly introductory offers, and unchanged
annual price/trial schedules. The annual offer remains $39.99 with seven days free for eligible
athletes from September 13. The app's preview/default monthly price, monthly CTA, terms, and derived
annual savings are updated. Production still uses the localized StoreKit price, including the current
price before the scheduled change. Build-for-testing succeeded and **21 tests passed** (16 billing/
reminder tests and five paywall UI tests), with zero failures/skips. Evidence:
`/tmp/momentum-monthly-999-verification.json` and `/tmp/momentum-monthly-999-tests.xcresult`.

**2026-09-11 — owner authorized the lower annual price and longer trial.** Apple rejected September 12
and required a price start date on or after September 13. The change uses the existing annual product,
its $39.99 USA price point, and Apple's 174 equalizations. Three-day offers end September 12; one-week
FREE_TRIAL offers begin September 13, avoiding overlapping date ranges. Lower, previously preserved
annual cohorts are retained; this operation does not un-preserve them. Monthly/weekly products and
RevenueCat product identifiers are unchanged. Read-back verification at 2026-09-11 21:39 UTC confirmed **175/175** scheduled prices,
**175/175** one-week trial offers, and **175/175** unchanged preserved-price rows. US monthly remains
$14.99. Apple returned intermittent HTTP 500 responses during writes; affected resources were read
back before retrying, and the final complete comparison passed. The local build passed, with 16
billing/reminder tests and five paywall UI tests passing. Evidence:
`/tmp/momentum-annual-pricing-verification.json` and `/tmp/momentum-pricing-tests.xcresult`.
This verifies saved configuration and simulator behavior; storefront propagation begins on the scheduled date.

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
- Offering: **`default`** with **weekly**, **annual** and (legacy, unsold) **monthly** packages (`$rc_weekly` / `$rc_annual` / `$rc_monthly`, verified 2026-09-13). The app sells the weekly and the annual; if a dashboard edit ever drops `$rc_weekly`, `loadOffering()` fetches `momentum_pro_weekly` by id and purchases it as a bare store product — the entitlement mapping in RevenueCat is what grants Pro either way. `loadOffering()` returns early unless BOTH resolve, so a missing package silently leaves the app on placeholder prices.
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
- Eligible fresh sandbox account → annual shows the current store offer: **7 days free** after September 13, with localized renewal terms; monthly has no trial. Previously used group trials remain ineligible.
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
