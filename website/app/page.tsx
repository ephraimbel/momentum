import Image from "next/image";
import PhoneFrame from "@/components/PhoneFrame";
import Reveal from "@/components/Reveal";
import Nav from "@/components/Nav";
import { athleteBlur } from "@/components/athleteBlur";
import { APP_STORE_URL, AppStoreBadge } from "@/components/appStore";

/** Structured data for the product itself — the prices here mirror the live App Store offering. */
const appSchema = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Momentum: Run Training Plans",
  operatingSystem: "iOS",
  applicationCategory: "HealthApplication",
  url: "https://momentumco.app",
  installUrl: APP_STORE_URL,
  offers: [
    { "@type": "Offer", price: "0", priceCurrency: "USD", description: "Free — track every run" },
    { "@type": "Offer", price: "9.99", priceCurrency: "USD", description: "momentum Pro, monthly" },
    {
      "@type": "Offer",
      price: "59.99",
      priceCurrency: "USD",
      description: "momentum Pro, annual — 7-day free trial",
    },
  ],
};

export default function Home() {
  return (
    <>
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(appSchema) }} />
      <Nav />
      <main id="top">
        <Hero />
        <Marquee />
        <BrandMoment />
        <Training />
        <Intelligence />
        <Method />
        <Pricing />
        <FAQ />
        <FinalCTA />
      </main>
      <Footer />
    </>
  );
}

/* ————————————————————————————————————————————————————————————
   1 · Hero — the brand moment. One dominant device, one idea.
   ———————————————————————————————————————————————————————————— */

function Hero() {
  return (
    <section className="hero">
      <div className="wrap hero-grid">
        <div>
          <Reveal>
            <p className="eyebrow">The running app</p>
          </Reveal>
          <Reveal>
            <h1>
              keep
              <br />
              moving.
            </h1>
          </Reveal>
          <Reveal>
            <p className="hero-copy">
              Training built around the runner you are today. Adaptive plans, guided runs, and
              coaching that changes as you do.
            </p>
          </Reveal>
          <Reveal>
            <div className="hero-actions">
              <a className="btn btn-ink" href={APP_STORE_URL} target="_blank" rel="noopener">
                Download Momentum <span className="arrow" aria-hidden>↗</span>
              </a>
              <a className="btn btn-ghost" href="#product">
                See how it works
              </a>
            </div>
            <p className="hero-micro">iPhone · Apple Watch · Garmin · Apple Health</p>
          </Reveal>
        </div>

        <div className="hero-stage">
          {/* The page's signature accent — iridescence haloing the product, and nowhere else. */}
          <div className="hero-orbit" aria-hidden />
          {/* Both chips read straight off the capture beside them — no invented numbers. */}
          <div className="stat-pill pill-1" aria-hidden>
            <b>26.22 mi</b>
            <small>Austin · 2:58:41</small>
          </div>
          <div className="stat-pill pill-2" aria-hidden>
            <b>6:49 /mi</b>
            <small>avg pace · 153 bpm</small>
          </div>
          <PhoneFrame
            src="/shots/hero-route.png"
            alt="A finished marathon in Momentum: 26.22 miles, the Austin route traced on the map, and the coach's read of the run."
            large
            priority
          />
        </div>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   2 · The distances — a thin editorial band, continuously moving.
   ———————————————————————————————————————————————————————————— */

function Marquee() {
  const line = (
    <span>
      <b>5K</b> · 10K · HALF · MARATHON · ULTRA · RUN/WALK · GET FASTER · GO FURTHER ·{" "}
    </span>
  );
  return (
    <div className="marquee" aria-hidden>
      <div className="marquee-track">
        {line}
        {line}
      </div>
    </div>
  );
}

/* ————————————————————————————————————————————————————————————
   3 · Dark cinematic transition — the emotional centre.
   ———————————————————————————————————————————————————————————— */

function BrandMoment() {
  return (
    <section className="brand-moment">
      <div className="brand-media">
        <Image
          src="/athletes/cinema-pack.jpg"
          alt="A pack of marathoners running through early-morning fog"
          fill
          sizes="100vw"
          placeholder="blur"
          blurDataURL={athleteBlur["cinema-pack.jpg"]}
        />
      </div>
      <div className="brand-shade" aria-hidden />
      {/* The app's own route motif, drawn over the photograph. */}
      <svg className="route-line" viewBox="0 0 900 700" fill="none" aria-hidden>
        <path
          d="M80 580C149 489 204 563 261 461C330 338 232 264 344 174C450 90 514 254 619 203C703 162 700 75 814 87"
          stroke="white"
          strokeWidth="4"
          strokeLinecap="round"
          strokeDasharray="2 12"
        />
        <circle cx="80" cy="580" r="7" fill="white" />
        <circle cx="814" cy="87" r="7" fill="white" />
      </svg>
      <div className="wrap brand-content">
        <Reveal>
          <h2>
            built for
            <br />
            the miles
            <br />
            ahead.
          </h2>
        </Reveal>
        <Reveal>
          <p className="brand-meta">
            <strong>06:14 AM · Austin, TX</strong>
            No feeds. No guilt loops. Just the next run, the next week, the next starting line.
          </p>
        </Reveal>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   4 · 01 · Training — two editorial product moments.
   ———————————————————————————————————————————————————————————— */

function Training() {
  return (
    <section className="section" id="product">
      <div className="wrap">
        <Reveal>
          <div className="section-head">
            <div>
              <p className="kicker">01 · Training</p>
              <h2 className="display">A plan that moves when you do.</h2>
            </div>
            <p className="lede">
              Momentum starts from your actual running history, then reshapes the week as your
              fitness, recovery, and life change.
            </p>
          </div>
        </Reveal>

        <div className="story-grid">
          <Reveal>
            <article className="story-card">
              <h3>Know what to run.</h3>
              <p>
                Base. Build. Peak. Taper. Every session has a reason, every pace has a purpose, and
                missed days simply move.
              </p>
              <div className="story-media">
                <PhoneFrame
                  src="/shots/plan.png"
                  alt="Momentum's weekly plan: a build week with strength days, a progression run, and an easy run, each with its target pace."
                />
              </div>
            </article>
          </Reveal>

          <Reveal>
            <article className="story-card dark">
              <h3>Run with guidance.</h3>
              <p>
                Pace bands, rep countdowns, heart-rate zones, and voice cues are there when you want
                them — then get out of the way.
              </p>
              <div className="story-media">
                <PhoneFrame
                  src="/shots/live-run.png"
                  alt="A guided run in progress: the live route, the current interval, target pace, and heart-rate zone."
                />
              </div>
            </article>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   5 · 02 · Intelligence — near-black, the coach as proof.
   ———————————————————————————————————————————————————————————— */

function Intelligence() {
  const notes = [
    "Plans adapt after every run",
    "Recovery changes tomorrow",
    "Every adjustment is explained",
  ];
  return (
    <section className="insight" id="intelligence">
      <div className="wrap">
        <Reveal>
          <div className="section-head">
            <div>
              <p className="kicker">02 · Intelligence</p>
              <h2 className="display">Your training knows the answer.</h2>
            </div>
            <p className="lede">
              AI explains. The training engine decides. Momentum keeps your plan grounded in actual
              running data instead of inventing numbers.
            </p>
          </div>
        </Reveal>

        <div className="coach-wrap">
          <Reveal>
            <div className="coach-copy">
              <h3>A coach that learns your running.</h3>
              <p>
                Ask what to run, how you&rsquo;re progressing, whether a goal is realistic, or why
                today&rsquo;s session changed. Every answer starts from your plan and your history.
              </p>
              <div className="coach-notes">
                {notes.map((n, i) => (
                  <div className="coach-note" key={n}>
                    <span>{n}</span>
                    <span>{String(i + 1).padStart(2, "0")}</span>
                  </div>
                ))}
              </div>
            </div>
          </Reveal>

          <Reveal>
            <div className="coach-stage">
              <div className="aurora" aria-hidden />
              <PhoneFrame
                src="/shots/coach.png"
                alt="The Momentum coach: a chat that opens with suggested questions about today's session, your trend, and what you could race."
              />
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   6 · 03 · The method — the philosophy, on paper.
   ———————————————————————————————————————————————————————————— */

function Method() {
  const principles = [
    {
      n: "01",
      t: "Missed sessions move.",
      d: "Life happens. The week reshapes itself instead of turning a missed run into failure.",
    },
    {
      n: "02",
      t: "Numbers you can trust.",
      d: "Paces, load, and zones come from bounded training logic, not generated guesswork.",
    },
    {
      n: "03",
      t: "Your training stays yours.",
      d: "Private by default. No public-performance pressure required to make progress.",
    },
  ];
  return (
    <section className="method" id="method">
      <div className="wrap">
        <Reveal>
          <p className="kicker">03 · The method</p>
          <h2 className="display">
            No red days.
            <br />
            No guilt loops.
            <br />
            Only momentum.
          </h2>
        </Reveal>
        <div className="principles">
          {principles.map((p) => (
            <Reveal key={p.n}>
              <article className="principle">
                <span className="num-label">{p.n}</span>
                <h3>{p.t}</h3>
                <p>{p.d}</p>
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   7 · 04 · Membership — one plan, stated plainly.
   ———————————————————————————————————————————————————————————— */

function Pricing() {
  const features = [
    "Adaptive training plan",
    "Guided workouts",
    "AI training coach",
    "Post-run analysis",
    "Recovery-aware adjustments",
    "Race projections",
    "Advanced history",
    "Apple Watch + Garmin support",
  ];
  return (
    <section className="pricing" id="pricing">
      <div className="wrap pricing-grid">
        <Reveal>
          <div>
            <p className="kicker">04 · Membership</p>
            <h2 className="display">
              One app.
              <br />
              Every run.
            </h2>
          </div>
        </Reveal>
        <Reveal>
          <div className="pricecard">
            <div className="price-row">
              <h3>momentum Pro</h3>
              <p className="price">
                $59.99 <span>/ year</span>
              </p>
            </div>
            <div className="features">
              {features.map((f) => (
                <div className="feature" key={f}>
                  {f}
                </div>
              ))}
            </div>
            <div className="price-actions">
              <a className="btn btn-ink" href={APP_STORE_URL} target="_blank" rel="noopener">
                Start 7 days free <span className="arrow" aria-hidden>↗</span>
              </a>
              <p className="price-note">
                Then $59.99/year — under $5 a month. Or $9.99/month without the trial.
                <br />
                Tracking every run is free, forever. Billed by Apple · cancel anytime.
              </p>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   8 · The questions runners actually ask — hairline rows, and the
   FAQPage structured data that has been earning search results.
   ———————————————————————————————————————————————————————————— */

function FAQ() {
  const items = [
    {
      q: "Is momentum free?",
      a: "Tracking every run is free, forever. momentum Pro — the full adaptive plan, AI coach, voice guidance, and advanced analytics — is $59.99/year with a 7-day free trial, which works out to under $5 a month. Prefer month to month? $9.99, no trial.",
    },
    {
      q: "Do I need an Apple Watch or heart-rate strap?",
      a: "No. Your iPhone handles GPS, pace, and guided workouts on its own. If you wear an Apple Watch, a Garmin, or a Bluetooth chest strap, momentum picks up live heart rate and zones automatically — no pairing flow, no exports.",
    },
    {
      q: "I've never run before. Is this for me?",
      a: "Especially for you. momentum starts from your actual starting point — run/walk intervals if that's where you are — and its honesty engine will tell you if a goal is too aggressive rather than setting you up to fail.",
    },
    {
      q: "How is momentum different from other running apps?",
      a: "The plan adapts after every run, protectively. Recovery signals, workload guardrails, and an injury-aware loop reshape your week within tested bounds — and the coach explains every change in plain language. AI narrates; it never invents your numbers.",
    },
    {
      q: "What happens to my data?",
      a: "Your runs live on your device first — every GPS point is saved as it happens, so nothing is ever lost. Health data stays in Apple Health under your control. Your map and history are private by default, and we never sell personal data. See our Privacy Policy for the full picture.",
    },
    {
      q: "What if I miss a workout?",
      a: "It moves. momentum reschedules it with a one-line explanation, and your streak survives — rest days count and one slipped day is forgiven. There is no red 'failed' state anywhere in the product.",
    },
  ];
  const faqSchema = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: items.map((it) => ({
      "@type": "Question",
      name: it.q,
      acceptedAnswer: { "@type": "Answer", text: it.a },
    })),
  };
  return (
    <section className="faq" id="faq">
      <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(faqSchema) }} />
      <div className="wrap faq-grid">
        <Reveal>
          <div>
            <p className="kicker">05 · Questions</p>
            <h2 className="display">Before you start.</h2>
          </div>
        </Reveal>
        <Reveal>
          <div className="faq-list">
            {items.map((it) => (
              <details key={it.q}>
                <summary>{it.q}</summary>
                <p className="faq-a">{it.a}</p>
              </details>
            ))}
          </div>
        </Reveal>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   9 · The closer — dark, huge, and the cropped wordmark.
   ———————————————————————————————————————————————————————————— */

function FinalCTA() {
  return (
    <section className="final" id="download">
      <div className="final-media">
        <Image
          src="/athletes/cinema-dusk.jpg"
          alt="A lone runner on wet pavement at dusk"
          fill
          sizes="100vw"
          placeholder="blur"
          blurDataURL={athleteBlur["cinema-dusk.jpg"]}
        />
      </div>
      <div className="final-shade" aria-hidden />
      <div className="wrap final-inner">
        <div className="final-top">
          <span>The running app</span>
          <span>From your first 5K to your first ultra</span>
        </div>
        <Reveal>
          <h2>
            keep
            <br />
            moving.
          </h2>
        </Reveal>
        <div className="final-bottom">
          <a className="appstore-badge" href={APP_STORE_URL} target="_blank" rel="noopener">
            <AppStoreBadge />
          </a>
          <p className="final-support">Bring a goal. Momentum will build the road there.</p>
        </div>
      </div>
      <p className="bigword" aria-hidden>
        momentum
      </p>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   10 · Footer — one quiet line.
   ———————————————————————————————————————————————————————————— */

function Footer() {
  return (
    <footer className="footerline">
      <div className="wrap">
        <span>© 2026 momentum, Inc. · Austin, TX</span>
        <nav className="footer-links" aria-label="Footer">
          <a href="mailto:support@momentumco.app">Support</a>
          <a href="/privacy">Privacy</a>
          <a href="/terms">Terms</a>
          <a href={APP_STORE_URL} target="_blank" rel="noopener">
            App Store
          </a>
        </nav>
        <span>Apple Health, Apple Watch, and App Store are trademarks of Apple Inc.</span>
      </div>
    </footer>
  );
}
