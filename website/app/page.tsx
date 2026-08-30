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
  url: "https://momentumrunning.app",
  installUrl: APP_STORE_URL,
  offers: [
    { "@type": "Offer", price: "0", priceCurrency: "USD", description: "Free — track every run" },
    { "@type": "Offer", price: "5.99", priceCurrency: "USD", description: "momentum Pro, weekly" },
    {
      "@type": "Offer",
      price: "29.99",
      priceCurrency: "USD",
      description: "momentum Pro, annual — $0.58 a week, save 90% vs weekly",
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
        <Gallery />
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
            <b>26.22 mi</b>
            <small>Austin Marathon · traced</small>
          </div>
          <div className="stat-pill pill-2" aria-hidden>
            <b>2:58:41</b>
            <small>Finish · 6:49 /mi</small>
          </div>
          <PhoneFrame
            src="/shots/hero-route.png"
            alt="A finished Austin Marathon in Momentum: the whole course traced in lavender across the city, 26.22 miles in 2:58:41 at 6:49 per mile."
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
              <p className="story-note">Week 4 · Recovery — a planned down week</p>
              <div className="story-media">
                <PhoneFrame
                  src="/shots/plan.png"
                  alt="Momentum's weekly plan: a marathon block 28 weeks out, showing a planned recovery week of 32 miles with an easy run, a recovery jog, two rest days, and a progression run."
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
                alt="The Momentum coach: asked to brief today, it lays out the session step by step — a 4 mile tempo at 8:25 per mile, the warm up and cool down around it, and the Z4 heart-rate band it should sit in."
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
              alt="Momentum's Fuel page: 3,050 calories against a 2,100 floor, roughly 390 grams of carbs banked for tomorrow's session, macro rings for carbs, protein, fat and sodium, and meals logged in plain language."
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
   6b · The rest of the app — the four screens the tour deck shows that the
        sections above don't. A WRAPPING grid, never a horizontal scroller:
        no page on this site moves sideways (owner rule 2026-08-20).
   ———————————————————————————————————————————————————————————— */

function Gallery() {
  const shots = [
    {
      src: "/shots/trends.png",
      cap: "Trends",
      note: "469 miles this year, 88 active days",
      alt: "Momentum's Trends: daily movement averaging 7.8 thousand steps, 144 miles this month against 469 this year, and a consistency heatmap of 88 active days over sixteen weeks.",
    },
    {
      src: "/shots/vitals.png",
      cap: "Vitals",
      note: "HRV, resting heart rate, breathing, temperature",
      alt: "Momentum's vitals: heart-rate variability at 68 milliseconds, three above normal, a resting heart rate of 52, breathing at 14.3 a minute and a wrist temperature of 34.6 degrees, each with its own trend.",
    },
    {
      src: "/shots/strength.png",
      cap: "Strength",
      note: "165,000 lb moved in seven days",
      alt: "Momentum's muscle load: 165 thousand pounds moved across every lift in seven days, split around a wheel by region — legs, arms, back, shoulders, core and chest.",
    },
    {
      src: "/shots/run-detail.png",
      cap: "Every run, kept",
      note: "10.16 mi · 1:30:12 · 8:53 /mi",
      alt: "A finished long run in Momentum: the Lady Bird Lake loop traced in lavender through Austin, 10.16 miles in 1 hour 30 at 8:53 per mile.",
    },
  ];
  return (
    <section className="section" id="more">
      <div className="wrap">
        <Reveal>
          <div className="section-head">
            <div>
              <p className="kicker">Everything else</p>
              <h2 className="display">The rest of the picture.</h2>
            </div>
            <p className="lede">
              Training is one screen of many. What you did, what it cost you, and what your body did
              about it — all of it kept, all of it yours.
            </p>
          </div>
        </Reveal>
        <div className="gallery">
          {shots.map((shot) => (
            <Reveal key={shot.src}>
              <figure className="gallery-item">
                <PhoneFrame src={shot.src} alt={shot.alt} />
                <figcaption>
                  <b>{shot.cap}</b>
                  <span>{shot.note}</span>
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
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
        The marathon RESULT moved up to the hero (2026-08-29), so this card shows the other half
        of the promise the copy already made — "a taper that delivers you to the start line
        ready" — and its three numbers quote the readiness screen beside them, not the finish.
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
                <b className="num">100</b>
                <small>Readiness · primed</small>
              </div>
              <div className="race-stat">
                <b className="num">7h 19m</b>
                <small>Sleep</small>
              </div>
              <div className="race-stat">
                <b className="num">0.89</b>
                <small>Training load</small>
              </div>
            </div>
          </div>
        </Reveal>
        <Reveal>
          <div className="race-media">
            <PhoneFrame
              src="/shots/readiness.png"
              alt="Momentum's readiness on race morning: a ring reading 100, primed, with the note 'well recovered — a good day to push', over the day's strain, training load and sleep."
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
                $0.58 <span>/ week</span>
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
                Get momentum Pro <span className="arrow" aria-hidden>↗</span>
              </a>
              <p className="price-note">
                $29.99 billed yearly — $0.58 a week, 90% off the weekly price. Or $5.99/week.
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
      a: "Tracking every run is free, forever. momentum Pro — the full adaptive plan, AI coach, voice guidance, and advanced analytics — is $29.99 billed yearly, which works out to $0.58 a week, 90% off the weekly price. Prefer to go week to week? $5.99.",
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
