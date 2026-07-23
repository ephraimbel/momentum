import Foundation

/// The single source of truth for "how we calculate" across the Progress page — every chart's
/// "ⓘ" pulls its plain-words explanation from here, so the science reads consistently and there's
/// one place to keep it honest. Content only; the presentation is `MetricDetailSheet`.
enum MetricExplainers {
    typealias E = MetricExplainer
    typealias S = MetricExplainer.Section

    // MARK: Endurance

    static let fitnessFreshness = E(
        id: "fitnessFreshness",
        title: "Fitness & Freshness",
        tagline: "The long game: how much training you've banked, and how recovered you are to use it.",
        formula: "Form = Fitness − Fatigue",
        sections: [
            S(heading: "Fitness (CTL)", body: "A 42-day rolling average of your daily training load. It rises slowly as you put in consistent work and fades slowly when you stop — so it tracks real, durable fitness, not a single good day."),
            S(heading: "Fatigue (ATL)", body: "The same idea over just 7 days, so it reacts fast to recent hard efforts. It spikes after a big week and settles within days of easing off."),
            S(heading: "Form", body: "Fitness minus Fatigue. Positive means you're fresh and race-ready; deeply negative means you're carrying a hard training block. Neither is 'good' or 'bad' — it depends on where you are in your plan."),
            S(heading: "How to read it", body: "Watch the shape over weeks. Fitness trending up while form dips is exactly what a build phase looks like; form climbing into the positive as a race nears is a healthy taper."),
        ])

    static let trainingLoad = E(
        id: "load",
        title: "Training Load",
        tagline: "One honest number for how much a session took out of you — across every sport.",
        formula: "Load = minutes × effort (1–10)",
        sections: [
            S(heading: "How we work it out", body: "We use session-RPE (the Foster method): your workout's duration in minutes times its effort on a 1–10 scale. A 60-minute run at effort 7 is a load of 420. When you don't rate a session, we use a sensible default effort for that sport."),
            S(heading: "Why minutes × effort", body: "It captures the two things that actually drive fatigue — how hard and how long — and it works the same for a run, a ride, or a lift, so your weekly total is comparable across everything you do."),
            S(heading: "How to read it", body: "Weekly load is the engine behind your fitness and freshness. Steady week-to-week growth builds fitness; big jumps are where injury risk lives."),
        ])

    static let cadence = E(
        id: "cadence",
        title: "Cadence",
        tagline: "How many steps you take per minute — a window into running efficiency.",
        formula: nil,
        sections: [
            S(heading: "How we work it out", body: "Each run records your average steps per minute; we average those across the runs in each week. The dashed line marks 180 spm, a commonly-cited efficient turnover."),
            S(heading: "Why it matters", body: "At a given pace, a quicker, lighter turnover usually means less time on the ground and gentler impact than long, bounding strides. It's a habit that tends to improve with easy volume."),
            S(heading: "How to read it", body: "There's no universal 'right' number — taller runners often run lower. Look for your own cadence drifting up over months, especially on easy runs."),
        ])

    static let climb = E(
        id: "climb",
        title: "Climb",
        tagline: "Total elevation you gained each week — the vertical in your training.",
        formula: nil,
        sections: [
            S(heading: "How we work it out", body: "As you move, GPS records altitude. We add up every uphill metre across your workouts in each week (downhills don't subtract — you still climbed them)."),
            S(heading: "Why it matters", body: "Climbing builds strength and durability that flat running can't, and it's the hidden reason a 'short' hilly run can feel harder than a long flat one. If you're training for a hilly race, this is the number to grow."),
            S(heading: "How to read it", body: "GPS altitude is approximate, so read the trend, not any single figure. Rising weekly climb is a sign you're getting stronger on terrain."),
        ])

    static let aerobicEfficiency = E(
        id: "efficiency",
        title: "Aerobic efficiency",
        tagline: "How steady your heart stays when you hold a pace — a read on aerobic fitness.",
        formula: "drift = (2nd-half HR:pace − 1st-half) ÷ 1st-half",
        sections: [
            S(heading: "How we work it out", body: "On a steady run of 20 minutes or more, we compare the ratio of heart rate to pace in the first half versus the second. If your heart climbs while your pace holds, that 'cardiac drift' shows up as a positive percentage. Needs a heart-rate source (Watch or strap)."),
            S(heading: "Why it matters", body: "A well-developed aerobic engine holds a pace without the heart creeping up. Low drift (under ~5%) is a hallmark of good aerobic fitness; high drift often means the effort was above your easy zone, or it was hot."),
            S(heading: "How to read it", body: "Lower is fitter. Compare similar easy runs over time — the same pace costing you less heart-rate drift is real aerobic progress."),
        ])

    static let vo2max = E(
        id: "vo2max",
        title: "VO₂max",
        tagline: "How much oxygen your body can use at full effort — the best single number for aerobic fitness.",
        sections: [
            S(heading: "How we work it out", body: "If your Apple Watch or Garmin has recorded a VO₂max, we show that measured value. Otherwise we estimate it from your recent 5K-equivalent pace using Daniels' VDOT model — the same science behind most GPS-watch estimates."),
            S(heading: "How to read it", body: "Higher is fitter, and the estimate sharpens as you log faster, harder efforts. It's an estimate, not a lab test — read the trend over weeks, not any single number. Your rating compares you to population norms for your age and sex."),
        ],
        footnote: "Not medical advice.")

    static let intensityMix = E(
        id: "intensityMix",
        title: "Intensity mix",
        tagline: "How your last four weeks split between easy and hard running — the 80/20 check.",
        formula: "target ≈ 80% easy · 20% hard",
        sections: [
            S(heading: "How we work it out", body: "We sort your recent runs into easy vs hard — by the session's prescription when there was one, otherwise by pace relative to your 5K fitness — and show the split as one bar against the 80/20 mark."),
            S(heading: "Why 80/20", body: "The most durable endurance athletes do the large majority of their running easy and save hard efforts for a focused minority. It's how you build volume without digging a hole."),
            S(heading: "How to read it", body: "If your easy share sits near or above 80%, you're polarised the right way. Creeping into too much 'medium-hard' is the classic way to plateau."),
        ])

    static let hrZones = E(
        id: "hrZones",
        title: "Heart-rate zones",
        tagline: "Where your heart actually spent the run — five personalised effort bands.",
        formula: "Karvonen: zone = rest + %·(max − rest)",
        sections: [
            S(heading: "How we work it out", body: "We build five zones from your max and resting heart rate using the Karvonen (heart-rate reserve) method, which is far more individual than a flat percentage of max. Then we total the time your heart spent in each."),
            S(heading: "How to read it", body: "Most of an easy run should live in the lower zones; quality sessions push the top ones. Seeing a supposedly easy run stacked in Zone 3+ is a sign it wasn't as easy as it felt."),
        ])

    // MARK: Strength

    static let liftProgression = E(
        id: "liftProgression",
        title: "Lift progression",
        tagline: "Your estimated one-rep max for a lift, session by session — are you getting stronger?",
        formula: "e1RM = weight × (1 + reps ⁄ 30)",
        sections: [
            S(heading: "How we work it out", body: "For each session we take your best working set of the lift and estimate the most you could do for a single rep, using the Epley formula. Charting that per session turns 'I lifted 100 kg for 5' into a clean strength curve."),
            S(heading: "Why an estimate", body: "You rarely test a true one-rep max — it's risky and you'd have to do it constantly. An estimate from your everyday working sets lets every session count as a data point, safely."),
            S(heading: "How to read it", body: "The trend is the point. A rising e1RM means real strength gains even when the weight on the bar looks similar; a plateau is your cue to change something."),
        ])

    static let trainingVolume = E(
        id: "trainingVolume",
        title: "Training volume",
        tagline: "Total weight you moved each week on your working sets.",
        formula: "volume = Σ (weight × reps)",
        sections: [
            S(heading: "How we work it out", body: "For every completed working set we multiply weight by reps and add it all up across the week. Warm-ups don't count — this is the meaningful work."),
            S(heading: "Why it matters", body: "Volume is the main driver of muscle growth and work capacity. Progressive overload — gradually moving more total weight over time — is what makes lifts go up."),
            S(heading: "How to read it", body: "Look for a gentle upward trend with the occasional lighter week to recover. Flat volume for months usually means flat progress."),
        ])

    static let muscleBalance = E(
        id: "muscleBalance",
        title: "Muscle balance",
        tagline: "Which muscles your recent lifting actually worked — and which you've been skipping.",
        formula: "sets = primary × 1.0 + secondary × 0.5",
        sections: [
            S(heading: "How we work it out", body: "Across the last four weeks we tally your working sets by muscle. A muscle a lift trains directly gets full credit; one it assists gets half. That's the standard way to count effective volume per muscle."),
            S(heading: "Why it matters", body: "Balanced training keeps you resilient and proportional. Chronically under-working a muscle group is how imbalances — and the niggles that follow — creep in."),
            S(heading: "How to read it", body: "The bars rank most- to least-worked. If something important sits at the bottom for weeks, it's a nudge to add a set or two there."),
        ])

    // MARK: Shared endurance charts (weekly distance / pace / recovery form)

    static let weeklyDistance = E(
        id: "weeklyDistance",
        title: "Weekly distance",
        tagline: "How far you ran each week — the simplest measure of endurance volume.",
        sections: [
            S(heading: "How we work it out", body: "We add up the GPS distance of every run inside each rolling seven-day window, so the most recent bar always reflects your last week of training."),
            S(heading: "How to read it", body: "Consistency beats heroics. A steady build with periodic down weeks is what safely grows endurance; sudden spikes are where injuries hide."),
        ])

    static let weeklyPace = E(
        id: "weeklyPace",
        title: "Weekly pace",
        tagline: "Your distance-weighted average running pace, week by week.",
        sections: [
            S(heading: "How we work it out", body: "For each week we average your running pace, weighted by distance so a long run counts more than a short one. Strength and other sports don't affect it."),
            S(heading: "How to read it", body: "Faster average pace over time is progress — but remember an easy-heavy week will read slower on purpose. Judge it alongside your intensity mix, not on its own."),
        ])

    static let recoveryForm = E(
        id: "recoveryForm",
        title: "Recovery & readiness",
        tagline: "Whether your recent load is building you up or wearing you down.",
        formula: "ACWR = last 7 days ÷ last 28 days (avg)",
        sections: [
            S(heading: "How we work it out", body: "We compare your acute load (this week) to your chronic load (your recent month, averaged). A ratio near 1 means this week looks like what your body is used to; well above it means a spike."),
            S(heading: "How to read it", body: "The sweet spot is roughly 0.8–1.3 — enough to build without overreaching. Persistently high means back off; very low for a while means there's room to add. When wearables provide HRV, resting HR, or sleep, we fold those in too."),
        ],
        footnote: "Not medical advice.")

    // MARK: Recovery hub (the §7 copy deck — RECOVERY-HUB-PLAN.md)

    /// Standing footnote on every recovery-hub sheet.
    private static let healthFootnote =
        "Guidance, never a diagnosis — if something feels wrong, talk to a professional."

    static let readiness = E(
        id: "readiness",
        title: "Readiness",
        tagline: "How ready your body is to absorb training today, in one honest number.",
        formula: "Readiness = weighted blend of HRV, resting heart rate, sleep, recent training load, and your check-in — same math every day.",
        sections: [
            S(heading: "What it is", body: "One 0–100 number for how ready your body is to absorb training today, blended from your overnight signals."),
            S(heading: "Why it matters", body: "Fitness is built in recovery, not in the workout — the session applies the stress, and your body adapts while you rest. Training hard on a body that hasn't finished adapting mostly adds fatigue, not fitness. Readiness times the hard days for when they'll actually count."),
            S(heading: "What moves it", body: "Sleep, alcohol, illness, stress, and how hard the last few days were. One low morning means little; a low week is your body asking for ease."),
        ],
        footnote: healthFootnote)

    static let hrv = E(
        id: "hrv",
        title: "HRV (heart-rate variability)",
        tagline: "The tiny variation between heartbeats — a nightly read on your nervous system.",
        sections: [
            S(heading: "What it is", body: "The tiny variation in time between heartbeats while you sleep — a read on your nervous system's balance."),
            S(heading: "Why it matters", body: "When you're recovered, the rest-and-digest side of your nervous system runs the show and the gaps between beats vary more. Under fatigue, stress, or oncoming illness, the fight-or-flight side takes over and the rhythm turns metronome-steady. Your trend against your own normal is the signal — comparing your number to anyone else's is meaningless."),
            S(heading: "What moves it", body: "Hard training, poor sleep, alcohol, and stress push it down; easy days, good sleep, and consistency bring it back."),
        ],
        footnote: healthFootnote)

    static let restingHR = E(
        id: "restingHR",
        title: "Resting heart rate",
        tagline: "Your heart's overnight idle speed — the slow-moving marker of fitness arriving.",
        sections: [
            S(heading: "What it is", body: "Your heart's idle speed, measured overnight when nothing is asked of it."),
            S(heading: "Why it matters", body: "A fitter heart moves more blood per beat, so it idles slower — watching it drift down across months is watching fitness arrive. A sudden jump of 5+ beats above your normal usually means your body is working on something: fatigue, dehydration, or fighting a bug."),
            S(heading: "What moves it", body: "Aerobic training lowers it over months. Alcohol, heat, late meals, and illness raise it overnight."),
        ],
        footnote: healthFootnote)

    static let respiratoryRate = E(
        id: "respiratoryRate",
        title: "Respiratory rate",
        tagline: "Breaths per minute while you sleep — the steadiest vital you own.",
        sections: [
            S(heading: "What it is", body: "How many breaths you take per minute while asleep."),
            S(heading: "Why it matters", body: "This is your steadiest vital — it barely moves night to night, which is exactly what makes it useful. A clear rise above your normal often shows up a day or two before you feel run down, making it a quiet early-warning line worth glancing at."),
            S(heading: "What moves it", body: "Very little, normally — which is the point. Illness, poor air, and heavy fatigue nudge it up."),
        ],
        footnote: healthFootnote)

    static let wristTemperature = E(
        id: "wristTemperature",
        title: "Wrist temperature",
        tagline: "Last night's skin temperature against your own baseline.",
        sections: [
            S(heading: "What it is", body: "How far your overnight skin temperature sat from your personal baseline."),
            S(heading: "Why it matters", body: "Your body runs a tight thermostat, so a real deviation means something's up — often the immune system getting to work before symptoms show, sometimes just a hot room or a late workout. It reads best alongside your other signals, not alone."),
            S(heading: "What moves it", body: "Illness, alcohol, late exercise, room temperature, and — for some — the menstrual cycle's natural rhythm, which the trend line makes visible."),
        ],
        footnote: healthFootnote)

    static let walkingHR = E(
        id: "walkingHR",
        title: "Walking heart rate",
        tagline: "Your heart's everyday cruising speed.",
        sections: [
            S(heading: "What it is", body: "The average heart rate of your ordinary daily walking — no workouts, just life. A worn Apple Watch measures it quietly across the day."),
            S(heading: "Why it matters", body: "Drifting up while training is flat is fatigue whispering before it shouts. Trending down across months is quiet, everyday proof your engine is growing."),
            S(heading: "What moves it", body: "Aerobic fitness lowers it slowly. Fatigue, heat, dehydration, and oncoming illness nudge it up — read it against your own normal, never anyone else's."),
        ],
        footnote: healthFootnote)

    static let sleepStages = E(
        id: "sleepStages",
        title: "Sleep stages (core, deep, REM)",
        tagline: "How the night split between core, deep, and REM — where recovery actually happens.",
        sections: [
            S(heading: "What it is", body: "The three kinds of work your brain and body cycle through at night — light (core), deep, and REM."),
            S(heading: "Why it matters", body: "Deep sleep is the body shift: growth hormone is released and muscle repair happens mostly there — it's where hard training gets banked. REM is the brain shift: skill, coordination, and mood consolidate. Core knits the cycles together. Runners shortchanging deep sleep are doing workouts they never fully cash in."),
            S(heading: "What moves it", body: "Deep sleep concentrates early in the night, so a consistent bedtime protects it. Alcohol is the biggest REM thief; caffeine after mid-afternoon cuts deep sleep."),
        ],
        footnote: healthFootnote)

    static let sleepDuration = E(
        id: "sleepDuration",
        title: "Sleep duration",
        tagline: "Hours actually asleep each night — the single biggest lever on how you absorb training.",
        sections: [
            S(heading: "What it is", body: "Time actually asleep each night, read from Apple Health — every source merged so each asleep minute counts once. Time in bed awake doesn't count."),
            S(heading: "Why it matters", body: "Sleep is where training converts to fitness: muscle repair, glycogen restocking, and skill consolidation all happen there. Across weeks, the trend matters more than any single night — a run of short nights quietly raises injury risk and flattens hard sessions before you feel tired."),
            S(heading: "How to read it", body: "Look for your steady level and how it holds through hard training blocks. One short night is noise; a drifting average is a signal worth acting on. Longer windows average by week, so the value keeps its per-night meaning."),
        ],
        footnote: healthFootnote)

    static let sleepDebt = E(
        id: "sleepDebt",
        title: "Sleep debt",
        tagline: "The gap between the sleep you've had and the sleep you need.",
        sections: [
            S(heading: "What it is", body: "The running gap between the sleep you've had and the sleep you need, over the last two weeks."),
            S(heading: "Why it matters", body: "Debt compounds quietly — reaction time, pace at a given heart rate, and injury resilience all slide as it builds, usually before you feel obviously tired. The good news: it pays down fast, and the chart shows it shrinking within a couple of honest nights."),
            S(heading: "What moves it", body: "Nightly duration versus your need. An earlier night beats a weekend lie-in — big catch-up sleeps shift your rhythm and cost you later."),
        ],
        footnote: healthFootnote)

    static let sleepConsistency = E(
        id: "sleepConsistency",
        title: "Sleep consistency",
        tagline: "How repeatable your bed and wake times are, night over night.",
        sections: [
            S(heading: "What it is", body: "How closely your bed and wake times repeat, night over night."),
            S(heading: "Why it matters", body: "Your body rehearses sleep before you're in bed — hormones and temperature start shifting on schedule. A steady schedule means deeper, more efficient sleep from the same hours; the same 7½ hours at random times genuinely restores less. It's the highest-leverage sleep habit, and it's free."),
            S(heading: "What moves it", body: "A regular lights-out and alarm — weekends included, within an hour or so."),
        ],
        footnote: healthFootnote)

    static let strain = E(
        id: "strain",
        title: "Strain",
        tagline: "Today's total load on your body — every workout and the day around it, one number.",
        sections: [
            S(heading: "What it is", body: "How much load today put on your body — every run, ride, and lift folded into one number, plus the everyday movement your legs still have to absorb."),
            S(heading: "Why it matters", body: "Strain isn't the enemy; it's the ingredient. Adaptation needs enough stress to signal “get stronger” — but stress only converts to fitness when recovery keeps pace. The number exists so hard days can be deliberately hard and easy days honestly easy, instead of everything blurring to medium."),
            S(heading: "What moves it", body: "Duration times intensity. Long easy work accumulates it slowly; intervals and racing spike it fast — and heat or hills raise the true cost of the same route."),
        ],
        footnote: healthFootnote)

    static let strainRecoveryBalance = E(
        id: "strainRecoveryBalance",
        title: "Strain–recovery balance",
        tagline: "What you're spending versus what you have to spend, side by side.",
        sections: [
            S(heading: "What it is", body: "The two curves together: what you're spending versus what you have to spend."),
            S(heading: "Why it matters", body: "Neither line means much alone — big strain on big recovery is a training block working; the same strain on a low-recovery week is where overreaching and injury quietly start. Weeks of peach-over-mint is the pattern worth acting on, and acting on it early is cheap."),
            S(heading: "What moves it", body: "You steer strain with your plan; recovery follows sleep and stress. When they drift apart, the fix is almost always an easier day or an earlier night — not more discipline."),
        ],
        footnote: healthFootnote)

    static let restDays = E(
        id: "restDays",
        title: "Rest days",
        tagline: "Planned days off — the part of training where the gains get built.",
        sections: [
            S(heading: "What it is", body: "Planned days of little or no training — a scheduled part of the program, not a hole in it."),
            S(heading: "Why it matters", body: "This is when the adaptation you trained for actually gets built — muscle repairs, energy stores refill, the nervous system resets. Skipping rest to “stay on track” trades next week's fitness for today's mileage; it's the most common way strong training blocks unravel."),
            S(heading: "What moves it", body: "Nothing to optimize — take them as planned. A kept rest day counts toward your streak, and your rhythm chart wears it proudly."),
        ],
        footnote: healthFootnote)

    static let whereDataComesFrom = E(
        id: "whereDataComesFrom",
        title: "Where this data comes from",
        tagline: "Every wearable arrives through Apple Health — and every band is your own normal.",
        sections: [
            S(heading: "One door: Apple Health", body: "Momentum reads every wearable through Apple Health — Apple Watch, Garmin, Oura, and Whoop all deliver their overnight signals there."),
            S(heading: "You'll need a wearable", body: "Sleep stages, HRV, resting heart rate, and the overnight vitals come from a watch or ring — a phone alone can't measure them, and the device must be set to sync with Apple Health. Without one, readiness still works from your training load and daily check-ins; it just reads with less signal."),
            S(heading: "Your own normal", body: "We never rank you against anyone; every band on every chart is your own normal, learned from your own nights."),
        ],
        footnote: healthFootnote)

    static let dailySteps = E(
        id: "dailySteps",
        title: "Daily movement",
        tagline: "The floor your training stands on — everything you walk between the workouts.",
        sections: [
            S(heading: "What it is",
              body: "Total steps per day, read from Apple Health — phone and watch combined, de-duplicated. Training shows up as peaks; this is the base underneath them."),
            S(heading: "Why it matters for endurance",
              body: "Easy, frequent movement builds the aerobic base and speeds recovery without adding training stress. A sustained drop in daily movement during hard training weeks is often the first quiet sign of accumulating fatigue."),
            S(heading: "How to read it",
              body: "Watch the 7-day average rather than any single day — travel days and rest days are supposed to dip. Consistency beats hero days."),
        ],
        footnote: "Steps come from Apple Health. No step goals here — the targets that matter live in your plan.")

    /// Every explainer, for tests + lookup by id.
    static let all: [MetricExplainer] = [
        fitnessFreshness, trainingLoad, cadence, climb, aerobicEfficiency, vo2max,
        intensityMix, hrZones, liftProgression, trainingVolume, muscleBalance,
        weeklyDistance, weeklyPace, recoveryForm, dailySteps,
        readiness, hrv, restingHR, respiratoryRate, wristTemperature, walkingHR,
        sleepStages, sleepDuration, sleepDebt, sleepConsistency, strain, strainRecoveryBalance,
        restDays, whereDataComesFrom,
    ]
}
