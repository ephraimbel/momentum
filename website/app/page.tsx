import Image from "next/image";
import PhoneFrame from "@/components/PhoneFrame";
import Reveal from "@/components/Reveal";
import RaceCalc from "@/components/RaceCalc";

export default function Home() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Proof />
        <Pillars />
        <Gallery />
        <DeepDives />
        <Predictor />
        <Goals />
        <Manifesto />
        <Principles />
        <Pricing />
        <FAQ />
        <FinalCTA />
      </main>
      <Footer />
    </>
  );
}

function Nav() {
  return (
    <header className="nav">
      <div className="wrap nav-inner">
        <a href="#top" aria-label="momentum home">
          <Image className="wordmark" src="/wordmark-black.png" alt="momentum" width={640} height={128} priority />
        </a>
        <nav className="nav-links" aria-label="Primary">
          <a href="#product">Product</a>
          <a href="#intelligence">Intelligence</a>
          <a href="#method">Method</a>
          <a href="#pricing">Pricing</a>
          <a href="#faq">FAQ</a>
          <a className="btn btn-ink btn-sm" href="#download">
            Get the app
          </a>
        </nav>
      </div>
    </header>
  );
}

function Hero() {
  return (
    <section className="hero" id="top">
      <div className="aura aura-1" aria-hidden />
      <div className="aura aura-2" aria-hidden />
      <div className="aura aura-3" aria-hidden />
      {/* The self-drawing route — the app's welcome motif, redrawn across the header. */}
      <svg className="hero-route" viewBox="0 0 1440 760" preserveAspectRatio="none" aria-hidden>
        <path d="M -60 470 C 180 380 260 560 470 470 S 760 300 980 400 S 1280 540 1520 380" />
      </svg>
      <div className="hero-runner" aria-hidden />
      <div className="wrap hero-grid">
        <div>
          <p className="eyebrow rise rise-1">The adaptive running coach</p>
          <h1 className="display rise rise-2">
            A coach that
            <br />
            learns how
            <br />
            <span className="iri-text">you</span> run.
          </h1>
          <p className="lede rise rise-3">
            momentum builds your training around your fitness, your recovery, and your life — then
            adapts it after every run. From your first 5K to your first ultra.
          </p>
          <div className="hero-ctas rise rise-4">
            <a className="btn btn-ink" href="#download">
               Download for iPhone
            </a>
            <a className="btn btn-ghost" href="#product">
              See how it works
            </a>
          </div>
          <p className="hero-note rise rise-4">Track free forever · Pro comes with a 7-day free trial</p>
          <div className="devices rise rise-4" aria-label="Works with">
            <span>iPhone</span>
            <span>Apple Watch</span>
            <span>Garmin</span>
            <span>Heart-rate straps</span>
            <span>Apple Health</span>
          </div>
        </div>
        <div className="rise rise-5">
          <PhoneFrame src="/shots/today-map.png" alt="momentum Today screen: your map, today's plan, and one Start button" priority />
        </div>
      </div>
    </section>
  );
}

function Proof() {
  const items = [
    { n: "±2%", l: "GPS distance accuracy" },
    { n: "0", l: "lost workouts — every fix saved as it lands" },
    { n: "5", l: "heart-rate zones, personalized to you" },
    { n: "60fps", l: "live map, even on long runs" },
  ];
  return (
    <section className="proof" aria-label="Engineering standards">
      <div className="wrap proof-grid">
        {items.map((it) => (
          <div className="proof-cell" key={it.l}>
            <div className="num">{it.n}</div>
            <p>{it.l}</p>
          </div>
        ))}
      </div>
    </section>
  );
}

function Pillars() {
  return (
    <section className="section" id="product">
      <div className="wrap">
        <Reveal>
          <div className="section-head">
            <p className="eyebrow">Why momentum</p>
            <h2 className="display">Training science first. AI where it helps.</h2>
            <p className="lede">
              Your paces, loads, and progressions come from a deterministic training engine — testable,
              bounded, honest. The AI explains the plan; it never invents your numbers.
            </p>
          </div>
        </Reveal>
        <div className="trio">
          <div className="card">
            <div className="glyph" aria-hidden>
              {/* route/plan */}
              <svg viewBox="0 0 24 24">
                <path d="M5 19c-1.7 0-2.5-2-1.2-3l8.4-6c1.3-1 .5-3-1.2-3H8" />
                <circle cx="18.5" cy="19" r="2.5" />
                <circle cx="5.5" cy="5" r="2.5" />
              </svg>
            </div>
            <h3>A plan, not a template</h3>
            <p>
              Built from your real history — momentum reads your recent runs from Apple Health and
              starts where you actually are, not where a quiz guesses you are.
            </p>
          </div>
          <div className="card">
            <div className="glyph" aria-hidden>
              {/* pace band / target */}
              <svg viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="9" />
                <circle cx="12" cy="12" r="4.5" />
                <circle cx="12" cy="12" r="0.5" />
              </svg>
            </div>
            <h3>Coached while you run</h3>
            <p>
              Guided intervals with live pace bands, 3-2-1 haptic countdowns, and a voice coach that
              tells you when to push and when to ease off.
            </p>
          </div>
          <div className="card">
            <div className="glyph" aria-hidden>
              {/* shield */}
              <svg viewBox="0 0 24 24">
                <path d="M12 3l7 3v5c0 4.4-3 8.4-7 10-4-1.6-7-5.6-7-10V6l7-3z" />
                <path d="M9 12l2 2 4-4" />
              </svg>
            </div>
            <h3>Protective by design</h3>
            <p>
              Recovery signals, workload guardrails, and an injury-aware loop that trains around a
              twinge instead of pretending it isn&apos;t there.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}

function Gallery() {
  const items = [
    {
      src: "/shots/plan.png",
      alt: "Training plan with week chips, Base phase label, and a long-run session card",
      h: "A periodized plan",
      p: "Base, build, and taper — every week labeled with why it exists, capped by workload guardrails.",
    },
    {
      src: "/shots/live-run.png",
      alt: "Live guided run: warm-up step with target pace, distance remaining, live heart rate in zone 2",
      h: "Coached mid-run",
      p: "Step-by-step guidance with target paces, rep countdowns, and your live heart-rate zone.",
    },
    {
      src: "/shots/coach.png",
      alt: "Coach chat asking how training is trending",
      h: "A coach you can ask",
      p: "Pace, programming, or how a session felt — answers grounded in your actual training data.",
    },
    {
      src: "/shots/profile-grid.png",
      alt: "Profile grid of workout tiles — route art and muscle maps",
      h: "Every run becomes art",
      p: "Your profile is a wall of routes and muscle maps — a private mirror of the work you've put in.",
    },
  ];
  return (
    <section className="section" id="gallery" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <Reveal>
          <div className="section-head center" style={{ textAlign: "center" }}>
            <p className="eyebrow">The whole journey</p>
            <h2 className="display">Plan it. Run it. Understand it.</h2>
          </div>
        </Reveal>
        <div className="gallery">
          {items.map((it, i) => (
            <Reveal key={it.h} delay={i * 100}>
              <figure>
                <PhoneFrame small src={it.src} alt={it.alt} />
                <figcaption>
                  <h4>{it.h}</h4>
                  <p>{it.p}</p>
                </figcaption>
              </figure>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function DeepDives() {
  return (
    <section className="section" id="intelligence" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <div className="duo">
          <div>
            <p className="eyebrow">Pace intelligence</p>
            <h3>A coach that reviews your run — not just records it.</h3>
            <p>
              After every guided session, momentum compares what was prescribed with what you ran,
              rep by rep, and gives you a verdict in plain language.
            </p>
            <ul>
              <li>
                <span className="tick" aria-hidden />
                On point, Ahead, Review, or Variable — judged against your prescribed pace bands
              </li>
              <li>
                <span className="tick" aria-hidden />
                Strong runs sharpen your future paces automatically
              </li>
              <li>
                <span className="tick" aria-hidden />
                Easing your targets always asks first — your plan never lurches
              </li>
            </ul>
          </div>
          <div className="duo-media">
            <PhoneFrame small src="/shots/pace-review.png" alt="Post-run pace review: six reps with verdicts and the coach's read" />
          </div>
        </div>

        <div className="duo flip">
          <div className="duo-media">
            <PhoneFrame small src="/shots/progress.png" alt="Progress trends: estimated VO2 max gauge and personalized heart-rate zones" />
          </div>
          <div>
            <p className="eyebrow">Your body, measured</p>
            <h3>Heart rate, zones, and recovery — from the gear you already own.</h3>
            <p>
              Apple Watch, Garmin, or a chest strap: live BPM and your current zone on the run
              screen, time-in-zones afterwards, and readiness signals that shape tomorrow&apos;s
              session.
            </p>
            <ul>
              <li>
                <span className="tick" aria-hidden />
                Zones personalized from your max and resting heart rate
              </li>
              <li>
                <span className="tick" aria-hidden />
                HRV, resting HR, and sleep flow in through Apple Health
              </li>
              <li>
                <span className="tick" aria-hidden />
                Every reading saved the moment it arrives
              </li>
            </ul>
          </div>
        </div>

        <div className="duo">
          <div>
            <p className="eyebrow">Your map</p>
            <h3>Every street you&apos;ve ever run, burned into your map.</h3>
            <p>
              A personal heatmap that traces your actual routes — the streets you repeat glow
              hotter. Suggested loops start and finish at your door, sized to today&apos;s session.
            </p>
            <ul>
              <li>
                <span className="tick" aria-hidden />
                Route suggestions drawn on the map before you commit
              </li>
              <li>
                <span className="tick" aria-hidden />
                Six base maps, satellite included — your choice everywhere
              </li>
              <li>
                <span className="tick" aria-hidden />
                Private by default. Your map is yours.
              </li>
            </ul>
          </div>
          <div className="duo-media">
            <PhoneFrame small src="/shots/heatmap-dark.png" alt="Personal heatmap tracing running routes across a dark city map" />
          </div>
        </div>
      </div>
    </section>
  );
}

function Predictor() {
  return (
    <section className="section" id="predictor" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <Reveal>
          <div className="section-head center" style={{ textAlign: "center" }}>
            <p className="eyebrow">Try the engine</p>
            <h2 className="display">What could you run?</h2>
            <p className="lede">
              Enter a recent result and the same deterministic model that calibrates momentum&apos;s
              training paces projects your other distances.
            </p>
          </div>
        </Reveal>
        <Reveal delay={80}>
          <RaceCalc />
        </Reveal>
      </div>
    </section>
  );
}

function Goals() {
  const goals = [
    { n: "5K", d: "Your first — or your fastest." },
    { n: "10K", d: "Speed meets staying power." },
    { n: "Half", d: "The distance that hooks you." },
    { n: "Marathon", d: "Twenty-six point two, built week by week." },
    { n: "Run/walk", d: "Brand new? Start exactly where you are." },
    { n: "Return", d: "Coming back from injury, gated and gradual." },
    { n: "Faster", d: "No race — just sharper paces." },
    { n: "Further", d: "Build the engine. Ultra is coming." },
  ];
  return (
    <section className="section" id="goals" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <Reveal>
          <div className="section-head">
            <p className="eyebrow">Every starting line</p>
            <h2 className="display">A plan for the runner you are today.</h2>
            <p className="lede">
              Pick the goal; momentum builds the road — and tells you honestly if the date is too
              tight.
            </p>
          </div>
        </Reveal>
        <div className="goals">
          {goals.map((g, i) => (
            <Reveal key={g.n} delay={(i % 4) * 70}>
              <div className="goal">
                <div className="num">{g.n}</div>
                <p>{g.d}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function Pricing() {
  return (
    <section className="section" id="pricing" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <Reveal>
          <div className="section-head center" style={{ textAlign: "center" }}>
            <p className="eyebrow">Pricing</p>
            <h2 className="display">A coach for less than a race entry.</h2>
            <p className="lede">
              Personal run coaching costs $150+ a month. momentum&apos;s adaptive engine trains you
              for a fraction of one session.
            </p>
          </div>
        </Reveal>
        <div className="plans">
          <Reveal>
            <div className="plan">
              <h3>Free</h3>
              <div className="plan-price">$0</div>
              <p className="plan-cycle">forever</p>
              <ul>
                <li><span className="tick" aria-hidden />Track every run — GPS, pace, splits, elevation</li>
                <li><span className="tick" aria-hidden />Live heart rate &amp; zones from your gear</li>
                <li><span className="tick" aria-hidden />Strength logging with the full exercise library</li>
                <li><span className="tick" aria-hidden />Your first adaptive training week</li>
                <li><span className="tick" aria-hidden />Recent history &amp; personal heatmap</li>
              </ul>
              <a className="btn btn-ghost" href="#download">Start free</a>
            </div>
          </Reveal>
          <Reveal delay={90}>
            <div className="plan plan-pro">
              <span className="plan-badge">7-day free trial</span>
              <h3>momentum Pro</h3>
              <div className="plan-price">
                $119.99 <small>/ year</small>
              </div>
              <p className="plan-cycle">
                7 days free, then $119.99/year (about $10/month) · or $19.99/month, cancel anytime
              </p>
              <ul>
                <li><span className="tick" aria-hidden />The full adaptive plan, recalibrated after every run</li>
                <li><span className="tick" aria-hidden />AI coach, post-run reads &amp; voice guidance</li>
                <li><span className="tick" aria-hidden />Recovery-aware training &amp; the injury loop</li>
                <li><span className="tick" aria-hidden />Advanced analytics, race predictions &amp; full history</li>
                <li><span className="tick" aria-hidden />Every share style &amp; watch premium</li>
              </ul>
              <a className="btn btn-ink" href="#download">Start your 7-day free trial</a>
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

function Manifesto() {
  return (
    <section className="section" id="method">
      <div className="wrap">
        <Reveal>
        <div className="manifesto">
          <div className="aura-m" aria-hidden />
          <p className="eyebrow">The method</p>
          <h2 className="display">
            No red days. No guilt loops. <span className="iri-text-dark">Only momentum.</span>
          </h2>
          <div className="manifesto-grid">
            <div>
              <h4>Missed sessions move.</h4>
              <p>
                Life happens. A missed run reschedules itself with a one-line rationale — there is no
                &ldquo;failed&rdquo; state anywhere in the app.
              </p>
            </div>
            <div>
              <h4>Streaks forgive.</h4>
              <p>
                Rest days count and one slipped day is forgiven. A streak should measure consistency,
                not perfection.
              </p>
            </div>
            <div>
              <h4>Numbers you can trust.</h4>
              <p>
                Every pace and load is computed by rules we can test — bounded, explainable, and
                never invented by a language model.
              </p>
            </div>
          </div>
        </div>
        </Reveal>
      </div>
    </section>
  );
}

function Principles() {
  // Honest by design: no fabricated testimonials. These are the commitments the product
  // actually holds itself to — each one is a real, shipped behavior, not social proof.
  const cards = [
    {
      title: "No red X, ever",
      body: "Miss a session and the plan moves with a one-line reason — it reschedules, it never shames. There is no “failed” state in momentum, by design.",
    },
    {
      title: "Real math, not vibes",
      body: "Every pace, load, and zone comes from a deterministic, tested engine — VDOT paces, training-load guardrails, personalized zones. The AI writes the explanation; it never invents the numbers.",
    },
    {
      title: "Your training stays yours",
      body: "Offline-first, owner-only, opt-in. No feed algorithm, no kudos games, nothing sold. Honest presence when you want it — never a public ledger you can’t leave.",
    },
  ];
  return (
    <section className="section" id="principles" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <Reveal>
          <div className="section-head center" style={{ textAlign: "center" }}>
            <p className="eyebrow">Why it’s built this way</p>
            <h2 className="display">No shame. Real math. Your data.</h2>
          </div>
        </Reveal>
        <div className="quotes">
          {cards.map((c, i) => (
            <Reveal key={c.title} delay={i * 90}>
              <figure className="quote">
                <div className="quote-name" style={{ fontSize: "1.15rem", marginBottom: ".55rem" }}>
                  {c.title}
                </div>
                <blockquote style={{ marginTop: 0 }}>{c.body}</blockquote>
              </figure>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function FAQ() {
  const items = [
    {
      q: "Is momentum free?",
      a: "Tracking every run is free, forever. momentum Pro — the full adaptive plan, AI coach, voice guidance, and advanced analytics — is $119.99/year with a 7-day free trial, or $19.99/month.",
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
  return (
    <section className="section" id="faq" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <Reveal>
          <div className="section-head center" style={{ textAlign: "center" }}>
            <p className="eyebrow">Questions</p>
            <h2 className="display">Everything runners ask us.</h2>
          </div>
        </Reveal>
        <Reveal>
          <div className="faq">
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

function FinalCTA() {
  return (
    <section className="cta" id="download">
      <div className="aura aura-3" aria-hidden style={{ left: "50%", transform: "translateX(-50%)", bottom: -260 }} />
      <div className="wrap">
        <h2 className="display">
          keep <span className="iri-text">moving.</span>
        </h2>
        <p className="lede center">
          Seven days of the full coach, free. Bring a goal — momentum will bring the plan.
        </p>
        <a className="btn btn-ink" href="#">
           Download on the App Store
        </a>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="footer">
      <div className="wrap">
        <div className="footer-grid">
          <div className="footer-brand">
            <Image className="wordmark-footer" src="/wordmark-black.png" alt="momentum" width={640} height={128} />
            <p>The adaptive running coach. From your first 5K to your first ultra — keep moving.</p>
          </div>
          <div>
            <h5>Product</h5>
            <div className="footer-col">
              <a href="#product">Why momentum</a>
              <a href="#intelligence">Intelligence</a>
              <a href="#method">The method</a>
              <a href="#download">Download</a>
            </div>
          </div>
          <div>
            <h5>Company</h5>
            <div className="footer-col">
              <a href="#principles">Principles</a>
              <a href="#faq">FAQ</a>
              <a href="mailto:hello@momentumco.app">Contact</a>
              <a href="mailto:press@momentumco.app">Press</a>
            </div>
          </div>
          <div>
            <h5>Legal</h5>
            <div className="footer-col">
              <a href="/privacy">Privacy Policy</a>
              <a href="/terms">Terms of Service</a>
              <a href="mailto:support@momentumco.app">Support</a>
            </div>
          </div>
        </div>
        <div className="footer-base">
          <p>© 2026 momentum, Inc. · Made in Austin, TX</p>
          <p>
            Apple Health, Apple Watch, and App Store are trademarks of Apple Inc. · Garmin is a
            trademark of Garmin Ltd.
          </p>
        </div>
      </div>
    </footer>
  );
}
