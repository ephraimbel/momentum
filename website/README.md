# momentum — marketing site

The Momentum landing page (Next.js 15, App Router, no UI libraries). The design system is lifted
1:1 from the iOS app: same ink/surface/hairline tokens, the five iridescent stops, and the exact
Space Grotesk + Inter font files the app bundles (both OFL). Screenshots in `public/shots/` are
real simulator captures — no mockup tooling — framed by a CSS device shell (`components/PhoneFrame`).

## Run

```bash
npm install
npm run dev        # http://localhost:3000
npm run build      # production build (fully static)
```

## Brand rules (mirror the app)

- ~95% monochrome. Iridescence is the earned accent — soft, blurred, never loud.
- Space Grotesk for display/numbers (`.display`, `.num` — tabular figures), Inter for UI/body.
- Light is the hero look; the dark "method" panel is the one deliberate inversion.
- No fabricated social proof — the proof band states engineering truths from the PRD quality bars.
