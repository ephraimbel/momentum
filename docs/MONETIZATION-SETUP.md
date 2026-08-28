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
| `momentum_pro_weekly` | 1 week  | $5.99  | — | yes — the entry plan |
| `momentum_pro_annual` | 1 year  | **$29.99** | — | yes — $0.58/wk, badge "SAVE 90%" |
| `momentum_pro_monthly`| 1 month | $9.99  | — | **no** — retired from the offering 2026-08-28 |

The monthly stays live but unsold: removing a product never cancels or re-prices an existing
subscriber, and keeping it is what lets the remaining monthly subs renew. NO product carries a
trial (retired 2026-08-20 — the soft paywall is the trial); the paywall's trial branches stay
data-driven off the store's intro offer, so a future offer lights them back up.

⚠️ **Price decreases flow to existing subscribers automatically at their next renewal** — the
"preserve price" option only exists for increases. The 2026-08-28 cut from $64.99 to $29.99
therefore re-prices every current annual subscriber, including the $59.99 cohort preserved
earlier that month.

These IDs must match `PaywallOffering.standard` in `PaywallController.swift`.

## 2. RevenueCat dashboard
- Create the project; add the App Store Connect app + shared secret.
- Entitlement: **`pro`**. Attach both products to it.
- Offering: **`default`** with a **weekly** and an **annual** package (`$rc_weekly` / `$rc_annual`). `loadOffering()` returns early unless BOTH resolve, so a missing package silently leaves the app on placeholder prices.
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
- Sandbox account → paywall shows **real localized prices**; NO plan shows a trial, and the annual wears its savings badge instead.
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
