# Social backend setup (Slice 6) — Supabase

> One-time activation runbook for the social backend: Supabase Auth (Sign in with Apple → JWT),
> the social tables + RLS, and photo/avatar Storage. Until these steps are done the app **ships
> dark**: local-only social, seeded community, deterministic AI templates — byte-identical to
> pre-Slice-6 behavior. Supersedes the auth/config sections of [SYNC-SETUP.md](SYNC-SETUP.md).

## 1. You do — Supabase dashboard (~10 minutes)

1. **Create the project** at [database.new](https://database.new) (any region close to you;
   save the database password in your password manager).
2. **Copy the credentials** from Settings → API:
   - Project URL (`https://<ref>.supabase.co`)
   - `anon` public key
3. **Enable the Apple provider**: Authentication → Sign In / Providers → Apple → enable.
   In **Client IDs**, enter the app's bundle ids (comma-separated):
   ```
   com.ephraimbel.momentum.app, com.ephraimbelachew.momentumdev
   ```
   (the second is the physical-device install id — see the device-install notes). That's ALL the
   native ID-token flow needs — **no** Services ID, secret key, or redirect URL (those are only
   for web OAuth).
4. **Apple Developer portal**: confirm the app identifier(s) have the **Sign in with Apple**
   capability (the entitlement is already in the Xcode project).

## 2. Code does — CLI (run from the repo root)

```sh
brew upgrade supabase              # ≥ 2.75 works; newer is better
supabase login
supabase link --project-ref <ref>  # the ref from your project URL
supabase db push                   # applies supabase/migrations/ (workouts, social core, storage, feed RPC)
supabase functions deploy workout-analysis coach-chat plan-narrate   # unchanged; JWT verification on
```

Sanity-check in the dashboard afterwards: Tables (`workouts`, `profiles`, `posts`, `follows`,
`blocks`, `reactions`, `comments`, `reports`), Storage buckets (`avatars` public,
`post-photos` private), and the `feed_page` function.

> No Docker? That's fine — `db push` runs against the cloud project. With Docker installed you
> can also run the whole stack locally (`supabase start` + `supabase db reset`) and point
> `SUPABASE_URL` at `http://127.0.0.1:54321`.

## 3. Wire the app secrets

Edit the untracked `Secrets.xcconfig` (copy from `Secrets.xcconfig.example` if missing):

```
// xcconfig gotcha: `//` starts a comment — the `$()` below is REQUIRED to keep the URL intact.
SUPABASE_URL = https:/$()/<ref>.supabase.co
SUPABASE_ANON_KEY = <anon key>
```

Then `xcodegen generate` and build. Empty values = the app ships dark (explicitly supported).

## 4. Verify

1. **RLS matrix**: paste `supabase/tests/rls_matrix.sql` into the SQL editor and run — it seeds
   two throwaway users inside a transaction, asserts the owner/stranger/follower/blocked
   visibility matrix, then rolls back. Expect `RLS matrix: all checks passed`.
2. **Auth**: in the app, Settings → Sign in with Apple → a user appears under Authentication →
   Users. Kill + relaunch: still signed in (Keychain session restore).
3. **Backup**: finish a workout → row in `workouts` (route present when shared + route-maps
   opted in, null when private). A second account must not see it.
4. **Social loop** (two sims/accounts): A publishes a public workout with photos → B
   pull-to-refreshes Community and sees it → follow/react/comment → A blocks B → B's copy
   disappears (feed *and* raw REST).

## Operational duties (App Store 1.2 — user-generated content)

- **Review reports within 24h**: the `reports` table is the audit trail (insert-only from
  clients; read it in the dashboard). Act on actionable ones (delete the post/comment via the
  dashboard — service role bypasses RLS) and set `status`.
- Blocks are enforced **server-side** (RLS, both directions) — no action needed, but don't
  weaken those policies.
- Terms of Service + Privacy Policy links live in Settings (already shipped).

## Privacy posture (docs/SOCIAL-LAYER.md)

Everything the server stores in `posts` is already **publish-redacted by the client**: location
is granularity-reduced or absent, the stat line respects "show exact numbers", and route
geometry is end-trimmed (~200 m) or absent entirely unless the athlete opted public route maps
in. The full-precision route exists only in `workouts`, readable by nobody but its owner. Be
honest in any user-facing copy: end-trimming is deterrence, not cryptographic protection — the
strong guarantee is that precise start/end points **never leave the device** on shared posts.
