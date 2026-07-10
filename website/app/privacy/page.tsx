import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";

export const metadata: Metadata = {
  title: "Privacy Policy — momentum",
  description: "How momentum handles your training data: on-device first, private by default, never sold.",
};

export default function Privacy() {
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
        <h1 className="display">Privacy Policy</h1>
        <p className="legal-date">Effective July 9, 2026</p>

        <p>
          momentum is built on a simple idea: your training data is yours. This policy explains what
          we collect, why, and the controls you have. The short version — your workouts live on your
          device first, everything social is opt-in and private by default, and we never sell
          personal data.
        </p>

        <h2>Data we collect</h2>
        <ul>
          <li>
            <strong>Workout data</strong> — GPS routes, pace, distance, duration, and the exercises
            you log. Recorded on your device as it happens so a dropped phone or dead battery never
            loses a workout.
          </li>
          <li>
            <strong>Health data (optional)</strong> — heart rate, resting heart rate, HRV, sleep,
            and body mass, read from Apple Health only after you grant permission. Used solely to
            personalize your training zones, recovery guidance, and calorie estimates.
          </li>
          <li>
            <strong>Account data</strong> — email address and profile details you provide, used to
            sync your training across devices.
          </li>
        </ul>

        <h2>How we use it</h2>
        <ul>
          <li>To build and adapt your training plan — computed by deterministic rules on your data.</li>
          <li>To show your own history, records, and personal heatmap. These are private by default.</li>
          <li>
            To generate coaching summaries. When AI features are enabled, workout summaries are
            processed server-side; your raw GPS routes are not required for this and health metrics
            are minimized.
          </li>
        </ul>

        <h2>What we never do</h2>
        <ul>
          <li>We never sell your personal data, and we never share it with advertisers or data brokers.</li>
          <li>We never make your location, routes, or health data public without an explicit opt-in.</li>
          <li>We never use your health data for anything other than the features you can see.</li>
        </ul>

        <h2>Apple Health</h2>
        <p>
          Health data is read only with your permission, is used only inside momentum, and is never
          transmitted to third parties or used for advertising, in accordance with Apple&apos;s
          HealthKit guidelines. You can revoke access at any time in the Health app; momentum keeps
          working without it.
        </p>

        <h2>Sharing and social</h2>
        <p>
          Every workout is <strong>visible to only you</strong> unless you change its visibility.
          If you choose to share, you control the audience, and route privacy zones let you hide
          where you start and finish.
        </p>

        <h2>Retention and deletion</h2>
        <p>
          You can export or permanently delete your data at any time from Profile → Settings →
          Data. Deletion removes your account and synced data from our servers within 30 days.
        </p>

        <h2>Contact</h2>
        <p>
          Questions or requests: <a href="mailto:privacy@momentum.run">privacy@momentum.run</a>.
        </p>
      </main>
    </>
  );
}
