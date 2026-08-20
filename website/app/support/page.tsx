import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";

export const metadata: Metadata = {
  title: "Support — momentum",
  description: "Get help with momentum: setup, Apple Health, your training plan, account and data.",
};

export default function Support() {
  return (
    <>
      <header className="nav">
        <div className="wrap nav-inner">
          <Link href="/" aria-label="momentum home">
            <Image className="wordmark" src="/wordmark-black.png" alt="momentum" width={640} height={128} priority />
          </Link>
          <nav className="nav-links" aria-label="Primary">
            <Link className="btn btn-ink btn-sm" href="/#download">
              Get the app
            </Link>
          </nav>
        </div>
      </header>
      <main className="legal">
        <h1 className="display">Support</h1>
        <p className="legal-date">We&apos;re here to help</p>

        <p>
          Need a hand with momentum? The fastest way to reach us is email — we read every message and
          usually reply within one business day.
        </p>

        <h2>Contact us</h2>
        <p>
          Email <a href="mailto:support@momentumco.app">support@momentumco.app</a> with your question. If
          it&apos;s about a specific workout or your plan, a quick note on what you expected vs. what
          happened helps us sort it fast.
        </p>

        <h2>Common questions</h2>
        <ul>
          <li>
            <strong>Getting started</strong> — Open the app, answer a few questions about your goal
            and schedule, and momentum builds your training plan. Grant location for run tracking and
            Apple Health for recovery-aware coaching when prompted.
          </li>
          <li>
            <strong>Apple Health isn&apos;t syncing</strong> — Open the Health app → Sharing →
            momentum, and make sure heart rate, resting heart rate, HRV, sleep, and workouts are
            enabled. momentum keeps working without Health; you just lose recovery-based adjustments.
          </li>
          <li>
            <strong>My run didn&apos;t track / the map looks off</strong> — Make sure location access
            is set to &ldquo;While Using the App&rdquo; and that you have a clear GPS signal. Every
            run is saved on your device as it happens, so a dropped signal never loses the workout.
          </li>
          <li>
            <strong>Changing your plan or race</strong> — Go to Plan → settings to update your goal
            race, weekly volume, or preferred training days; the plan re-adapts.
          </li>
          <li>
            <strong>Account, export, or deletion</strong> — Profile → Settings → Data lets you export
            or permanently delete your data at any time.
          </li>
        </ul>

        <h2>Privacy &amp; terms</h2>
        <p>
          See our <Link href="/privacy">Privacy Policy</Link> for how your training and health data
          are handled (on-device first, private by default, never sold) and our{" "}
          <Link href="/terms">Terms of Use</Link>.
        </p>

        <h2>Still stuck?</h2>
        <p>
          Email <a href="mailto:support@momentumco.app">support@momentumco.app</a> and we&apos;ll get you
          moving again.
        </p>
      </main>
    </>
  );
}
