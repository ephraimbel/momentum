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
Create two auto-renewing subscriptions in one group (pricing decided 2026-07-14 — monthly set below Runna):

| Product ID | Duration | Price | Intro offer |
|---|---|---|---|
| `momentum_pro_monthly` | 1 month | $14.99 | — |
| `momentum_pro_annual`  | 1 year  | $109.99 | **7-day free trial** |

These IDs must match `PaywallOffering.standard` in `PaywallController.swift`.

## 2. RevenueCat dashboard
- Create the project; add the App Store Connect app + shared secret.
- Entitlement: **`pro`**. Attach both products to it.
- Offering: **`default`** with a **monthly** and an **annual** package.
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
- Sandbox account → paywall shows **real localized prices**; the annual plan shows the **7-day trial**.
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
