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

    /// Every explainer, for tests + lookup by id.
    static let all: [MetricExplainer] = [
        fitnessFreshness, trainingLoad, cadence, climb, aerobicEfficiency, vo2max,
        intensityMix, hrZones, liftProgression, trainingVolume, muscleBalance,
        weeklyDistance, weeklyPace, recoveryForm,
    ]
}
