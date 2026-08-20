import PhoneFrame from "@/components/PhoneFrame";
import Reveal from "@/components/Reveal";
import Nav from "@/components/Nav";
import InkReveal from "@/components/InkReveal";
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
        <Statement />
        <Training />
        <Intelligence />
        <Fuel />
        <Method />
        <RaceDay />
        <Pricing />
        <FAQ />
        <FinalCTA />
      </main>
      <Footer />
    </>
  );
}

/* ————————————————————————————————————————————————————————————
   1 · Hero — two-tone statement, one dominant device, live dot.
   ———————————————————————————————————————————————————————————— */

function Hero() {
  return (
    <section className="hero">
      <div className="wrap hero-grid">
        <div>
          <Reveal>
            <a className="live-pill" href={APP_STORE_URL} target="_blank" rel="noopener">
              <span className="live-dot" aria-hidden />
              Live on the App Store
            </a>
          </Reveal>
          <Reveal>
            <h1>
              Training that adapts
              <br />
              <span className="dim">to every run.</span>
            </h1>
          </Reveal>
          <Reveal>
            <p className="hero-copy">
              Adaptive plans, guided runs, and coaching built around the runner you are today —
              from your first 5K to your first ultra.
            </p>
          </Reveal>
          <Reveal>
            <div className="hero-actions">
              {/* iOS is the only place to get momentum, so the primary CTA is Apple's own badge. */}
              <a
                className="appstore-badge"
                href={APP_STORE_URL}
                target="_blank"
                rel="noopener"
                aria-label="Download momentum on the App Store"
              >
                <AppStoreBadge />
              </a>
              <a className="btn btn-ghost" href="#product">
                See how it works
              </a>
            </div>
            <p className="hero-micro">IPHONE · APPLE WATCH · APPLE HEALTH</p>
          </Reveal>
        </div>

        <div className="hero-stage">
          {/* The page's one decorative iridescence — a faint aurora haloing the product. */}
          <div className="hero-orbit" aria-hidden />
          {/* Both chips quote the capture beside them — no invented numbers. */}
          <div className="stat-pill pill-1" aria-hidden>
            <b>Easy 3.5 mi</b>
            <small>Today&rsquo;s plan · 11:45 /mi</small>
          </div>
          <div className="stat-pill pill-2" aria-hidden>
            <b>26.2 mi</b>
            <small>Austin Marathon · traced</small>
          </div>
          <PhoneFrame
            src="/shots/hero-route.png"
            alt="Momentum's Today screen: the Austin Marathon course traced in lavender on a light map, with today's planned easy run ready to start."
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
   3 · The statement — words inking in as you scroll.
   ———————————————————————————————————————————————————————————— */

function Statement() {
  return (
    <section className="statement">
      <div className="wrap">
        <InkReveal text="momentum is a coach, not a feed. It learns your body, reshapes your week around your recovery, and tells you the truth about your goal." />
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   4 · 01 · Training — two stage cards, the product doing the talking.
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
              <p className="story-note">Week 1 · Base — laying the foundation</p>
              <div className="story-media">
                <PhoneFrame
                  src="/shots/plan.png"
                  alt="Momentum's weekly plan: a base week with an easy run and a strength day, each with its target."
                />
              </div>
            </article>
          </Reveal>

          <Reveal>
            <article className="story-card dark">
              <h3>Run with guidance.</h3>
              <p>
                Pace bands, rep countdowns, heart-rate zones, and voice cues are there when you want
                them, then get out of the way.
              </p>
              <p className="story-note">Rep 2 of 6 · recovery · 8:56 /mi</p>
              <div className="story-media">
                <PhoneFrame
                  src="/shots/live-run.png"
                  alt="A guided run in progress: the live lavender route trace, the current recovery interval, distance, pace, and heart-rate zone."
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
   5 · 02 · Intelligence — warm charcoal, the coach as proof.
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
                alt="The Momentum coach: a chat that opens with suggested questions about today's session, your last workout, and what you could race."
              />
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   6 · 03 · Fuel — the one vivid room, shown not told.
   ———————————————————————————————————————————————————————————— */

function Fuel() {
  return (
    <section className="section" id="fuel">
      <div className="wrap duo">
        <Reveal>
          <div className="duo-media">
            <PhoneFrame
              src="/shots/fuel.png"
              alt="Momentum's Fuel page: calories and carbs banked for tomorrow's session, macro rings, and meals logged in plain language."
            />
          </div>
        </Reveal>
        <Reveal>
          <div className="duo-copy">
            <p className="kicker">03 · Fuel</p>
            <h3>Fuel the work. Never a diet.</h3>
            <p>
              Floors, not ceilings: enough carbs banked for tomorrow&rsquo;s session, enough sodium
              for the heat, logged in plain language. Describe the meal in your own words and
              momentum does the numbers.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   7 · 04 · The method — numbered hairline rows.
   ———————————————————————————————————————————————————————————— */

function Method() {
  const principles = [
    {
      n: "01",
      t: "Missed sessions move.",
      d: "Life happens. The week reshapes itself instead of turning a missed run into failure. There is no red 'failed' state anywhere in the product.",
    },
    {
      n: "02",
      t: "Numbers you can trust.",
      d: "Paces, load, and zones come from bounded, tested training logic. AI narrates the why; it never computes your numbers.",
    },
    {
      n: "03",
      t: "Your training stays yours.",
      d: "Private by default, on your device first. No feeds, no kudos economy, no public-performance pressure required to make progress.",
    },
  ];
  return (
    <section className="method" id="method">
      <div className="wrap">
        <Reveal>
          <p className="kicker">04 · The method</p>
          <h2 className="display" style={{ marginTop: 16 }}>
            No red days. <span className="dim">Only momentum.</span>
          </h2>
        </Reveal>
        <div className="rows">
          {principles.map((p) => (
            <Reveal key={p.n}>
              <div className="row">
                <span className="num-label">{p.n}</span>
                <h3>{p.t}</h3>
                <p>{p.d}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   8 · Race day — the charcoal proof card. The numbers quote the capture.
   ———————————————————————————————————————————————————————————— */

function RaceDay() {
  return (
    <section className="race" id="raceday">
      <div className="race-grid">
        <Reveal>
          <div>
            <p className="kicker">Race day</p>
            <h2>Bring a goal. momentum builds the road there.</h2>
            <p>
              Honest verdicts on what you can run today, projections that sharpen as you train, and
              a taper that delivers you to the start line ready.
            </p>
            <div className="race-stats">
              <div className="race-stat">
                <b className="num">26.22 mi</b>
                <small>Austin Marathon</small>
              </div>
              <div className="race-stat">
                <b className="num">2:58:41</b>
                <small>Finish · sub-3</small>
              </div>
              <div className="race-stat">
                <b className="num">6:49 /mi</b>
                <small>Avg pace</small>
              </div>
            </div>
          </div>
        </Reveal>
        <Reveal>
          <div className="race-media">
            <PhoneFrame
              src="/shots/run-detail.png"
              alt="A finished marathon in Momentum: the Austin course traced in lavender, 26.22 miles in 2:58:41 at 6:49 per mile."
            />
          </div>
        </Reveal>
      </div>
    </section>
  );
}

/* ————————————————————————————————————————————————————————————
   9 · 05 · Membership — one plan, stated plainly.
   ———————————————————————————————————————————————————————————— */

function Pricing() {
  const features = [
    "Adaptive training plan",
    "Guided workouts",
    "AI training coach",
    "Post-run analysis",
    "Recovery-aware adjustments",
    "Race projections",
    "Fueling floors",
    "Apple Watch + Garmin support",
  ];
  return (
    <section className="pricing" id="pricing">
      <div className="wrap pricing-grid">
        <Reveal>
          <div>
            <p className="kicker">05 · Membership</p>
            <h2 className="display">
              One app.
              <br />
              <span className="dim">Every run.</span>
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
   10 · The questions runners actually ask (+ FAQPage schema).
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
            <p className="kicker">06 · Questions</p>
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
   11 · The closer — one huge rounded charcoal card.
   ———————————————————————————————————————————————————————————— */

function FinalCTA() {
  return (
    <div className="final-outer">
      <section className="final" id="download">
        <div className="final-top">
          <span>The running app</span>
          <span>From your first 5K to your first ultra</span>
        </div>
        <div className="final-mid">
          <Reveal>
            <h2>
              keep
              <br />
              moving.
            </h2>
          </Reveal>
        </div>
        <div>
          <div className="final-bottom">
            <a className="appstore-badge" href={APP_STORE_URL} target="_blank" rel="noopener">
              <AppStoreBadge />
            </a>
            <p className="final-support">Bring a goal. Momentum will build the road there.</p>
          </div>
          <p className="bigword" aria-hidden>
            momentum
          </p>
        </div>
      </section>
    </div>
  );
}

/* ————————————————————————————————————————————————————————————
   12 · Footer — one quiet line.
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
