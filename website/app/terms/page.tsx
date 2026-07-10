import type { Metadata } from "next";
import Link from "next/link";
import Image from "next/image";

export const metadata: Metadata = {
  title: "Terms of Service — momentum",
  description: "The terms that govern your use of momentum.",
};

export default function Terms() {
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
        <h1 className="display">Terms of Service</h1>
        <p className="legal-date">Effective July 9, 2026</p>

        <p>
          These terms govern your use of the momentum app and website (the &ldquo;Service&rdquo;),
          operated by momentum, Inc. By creating an account or using the Service you agree to them.
        </p>

        <h2>1. Not medical advice</h2>
        <p>
          momentum provides training guidance computed from your data. It is <strong>not</strong> a
          medical device and does not provide medical advice, diagnosis, or treatment. Consult a
          physician before starting a new training program, and stop and seek medical attention if
          you experience pain, dizziness, or other concerning symptoms. Never ignore professional
          medical advice because of something momentum showed you.
        </p>

        <h2>2. Your account</h2>
        <p>
          You must be at least 16 years old to use the Service. You are responsible for your
          account credentials and for the accuracy of the information you provide.
        </p>

        <h2>3. Subscriptions</h2>
        <p>
          momentum Pro is an auto-renewing subscription billed through the App Store. Pricing is
          shown before purchase; you can cancel anytime in your App Store settings and Pro remains
          active until the end of the paid period. App Store purchases are subject to Apple&apos;s
          terms, and refunds are handled by Apple.
        </p>

        <h2>4. Your content</h2>
        <p>
          You own your training data and anything you share. You grant us the limited license
          needed to operate the Service — to store, sync, and display your content to you and to
          the audience you choose. We claim no other rights to it.
        </p>

        <h2>5. Acceptable use</h2>
        <p>
          Don&apos;t misuse the Service: no unlawful use, no attempting to access other users&apos;
          data, no reverse-engineering, and no scraping. Community features must be used with
          respect for other athletes.
        </p>

        <h2>6. Assumption of risk</h2>
        <p>
          Running and strength training carry inherent risks. You participate at your own risk and
          are responsible for training within your abilities and for your awareness of your
          surroundings — including while using guided workouts, audio cues, or navigation.
        </p>

        <h2>7. Disclaimers and liability</h2>
        <p>
          The Service is provided &ldquo;as is.&rdquo; To the maximum extent permitted by law,
          momentum, Inc. disclaims all warranties and is not liable for indirect, incidental, or
          consequential damages arising from your use of the Service. Our total liability is
          limited to the amount you paid us in the twelve months before the claim.
        </p>

        <h2>8. Termination</h2>
        <p>
          You can delete your account at any time. We may suspend accounts that violate these
          terms. Sections that by their nature survive termination do so.
        </p>

        <h2>9. Changes</h2>
        <p>
          We may update these terms; material changes will be announced in the app before they take
          effect. Continued use after the effective date constitutes acceptance.
        </p>

        <h2>Contact</h2>
        <p>
          <a href="mailto:legal@momentum.run">legal@momentum.run</a>
        </p>
      </main>
    </>
  );
}
