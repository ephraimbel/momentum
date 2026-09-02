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
        tagline: "Long- and short-term training-load trends in one view.",
        formula: "Form = Fitness − Fatigue",
        sections: [
            S(heading: "Fitness (CTL)", body: "Our label for a 42-day exponentially weighted average of recorded training load. It changes slowly and describes training exposure; it is not a direct measurement of fitness."),
            S(heading: "Fatigue (ATL)", body: "Our label for the same load calculation over 7 days. It reacts faster to recent work, but it does not directly measure fatigue."),
            S(heading: "Form", body: "Long-term load minus recent load. A positive or negative value describes the relationship between those two estimates; it does not clear you to race or diagnose recovery."),
            S(heading: "How to read it", body: "Use the shape over weeks to understand how plan demand is changing. Read it with session purpose, your response, and recovery context rather than chasing a universal number."),
        ],
        source: MetricExplainer.Source("Banister EW. Modeling elite athletic performance. In: Physiological Testing of the High-Performance Athlete. Human Kinetics, 1991.", "https://www.trainingpeaks.com/learn/articles/the-science-of-the-performance-manager/"))

    static let trainingLoad = E(
        id: "load",
        title: "Training Load",
        tagline: "A consistent estimate of session demand across every sport.",
        formula: "Load = minutes × effort (1–10)",
        sections: [
            S(heading: "How we work it out", body: "We use session-RPE (the Foster method): duration in minutes times your effort on a 1–10 scale. A 60-minute run at effort 7 is a load of 420. When a rating is missing, the app uses a documented discipline fallback, so confidence is lower."),
            S(heading: "Why minutes × effort", body: "Duration and perceived effort provide one practical way to compare recorded training demand across a run, ride, or lift. The result is an estimate, not a physiological measurement."),
            S(heading: "How to read it", body: "Weekly load is one part of the fitness-and-fatigue picture. Read changes alongside the session type, your recovery, and how the work felt; the same total can land differently in different weeks."),
        ],
        source: MetricExplainer.Source("Foster C, et al. A new approach to monitoring exercise training. J Strength Cond Res. 2001;15(1):109–115.", "https://pubmed.ncbi.nlm.nih.gov/11708692/"))

    static let cadence = E(
        id: "cadence",
        title: "Cadence",
        tagline: "How many steps you take per minute while running.",
        formula: nil,
        sections: [
            S(heading: "How we work it out", body: "Each run records average steps per minute; we average those values across the runs in each week. The 180-spm line is a familiar reference, not a target or efficiency test."),
            S(heading: "Why it matters", body: "Deliberately changing step rate can change running mechanics, but a higher number is not automatically better. Pace, height, terrain, fatigue, and individual movement patterns all affect cadence."),
            S(heading: "How to read it", body: "Compare similar runs against your own range. A change can be useful context, especially when pace or terrain also changed, but the chart does not prescribe a universal cadence."),
        ],
        source: MetricExplainer.Source("Heiderscheit BC, et al. Effects of step rate manipulation on joint mechanics during running. Med Sci Sports Exerc. 2011;43(2):296–302.", "https://pubmed.ncbi.nlm.nih.gov/20581720/"))

    static let climb = E(
        id: "climb",
        title: "Climb",
        tagline: "Total elevation you gained each week — the vertical in your training.",
        formula: nil,
        sections: [
            S(heading: "How we work it out", body: "As you move, GPS records altitude. We add up every uphill metre across your workouts in each week (downhills don't subtract — you still climbed them)."),
            S(heading: "Why it matters", body: "Hills change the muscular and cardiovascular demand of a run, so distance alone can hide part of the workload. Terrain-specific exposure also matters when the goal event is hilly."),
            S(heading: "How to read it", body: "GPS altitude is approximate, so compare trends across similar routes and devices. More weekly climb means more uphill exposure, not automatic proof of improved strength or performance."),
        ])

    static let aerobicEfficiency = E(
        id: "efficiency",
        title: "Aerobic efficiency",
        tagline: "How heart-rate-to-pace changed across a steady run.",
        formula: "drift = (2nd-half HR:pace − 1st-half) ÷ 1st-half",
        sections: [
            S(heading: "How we work it out", body: "On a steady run of 20 minutes or more, we compare the ratio of heart rate to pace in the first half versus the second. If your heart climbs while your pace holds, that 'cardiac drift' shows up as a positive percentage. Needs a heart-rate source (Watch or strap)."),
            S(heading: "Why it matters", body: "Cardiovascular drift can reflect duration, intensity, heat, hydration, terrain, and aerobic conditioning. No single percentage identifies fitness or an easy zone for every runner."),
            S(heading: "How to read it", body: "Compare steady runs with similar duration, route, weather, and effort. A repeated change may add useful context, but one run cannot establish aerobic progress on its own."),
        ],
        source: MetricExplainer.Source("Coyle EF, González-Alonso J. Cardiovascular drift during prolonged exercise. Exerc Sport Sci Rev. 2001;29(2):88–92.", "https://pubmed.ncbi.nlm.nih.gov/11337828/"))

    static let vo2max = E(
        id: "vo2max",
        title: "VO₂max",
        tagline: "An estimate related to maximal aerobic capacity.",
        sections: [
            S(heading: "How we work it out", body: "If a permitted source has written a VO₂max estimate to Apple Health, we show it. Otherwise we derive a VDOT-style estimate from a recent explicit running benchmark. Neither path is a direct lab measurement."),
            S(heading: "How to read it", body: "Use a consistent source and read the trend over multiple comparable efforts. Weather, terrain, device algorithms, and benchmark quality can move the estimate, and running performance depends on more than this number."),
        ],
        footnote: "Not medical advice.",
        source: MetricExplainer.Source("Daniels J. Daniels' Running Formula, 4th ed. Human Kinetics, 2021.", "https://us.humankinetics.com/products/daniels-running-formula-4th-edition"))

    static let intensityMix = E(
        id: "intensityMix",
        title: "Intensity mix",
        tagline: "How your last four weeks split between easy and quality running.",
        formula: "recent easy share = easy runs ÷ classified runs",
        sections: [
            S(heading: "How we work it out", body: "We sort your recent runs into easy versus quality — by the session's prescription when there was one, otherwise by pace relative to your 5K estimate. The 80% marker is a familiar reference, not a pass/fail target."),
            S(heading: "How to read it", body: "Most distance-running programs keep the majority of volume easy, but the exact split varies by event, phase, athlete, and classification method. Use the trend to catch accidental medium-hard running, not to chase one universal percentage."),
        ],
        source: MetricExplainer.Source("Seiler S. What is best practice for training intensity and duration distribution in endurance athletes? Int J Sports Physiol Perform. 2010;5(3):276–291.", "https://pubmed.ncbi.nlm.nih.gov/20861519/"))

    static let hrZones = E(
        id: "hrZones",
        title: "Heart-rate zones",
        tagline: "Where your heart actually spent the run — five personalised effort bands.",
        formula: "Karvonen: zone = rest + %·(max − rest)",
        sections: [
            S(heading: "How we work it out", body: "We estimate five zones from the max and resting heart rates available to the app using the Karvonen heart-rate-reserve method, then total recorded time in each. Estimated or stale inputs lower confidence."),
            S(heading: "How to read it", body: "Use zones with session intent and perceived effort. Heat, hills, fatigue, medication, sensor error, and individual thresholds can all shift heart rate, so a zone chart does not overrule how the run felt."),
        ],
        source: MetricExplainer.Source("Karvonen MJ, Kentala E, Mustala O. The effects of training on heart rate. Ann Med Exp Biol Fenn. 1957;35(3):307–315.", "https://pubmed.ncbi.nlm.nih.gov/13470504/"))

    // MARK: Strength

    static let liftProgression = E(
        id: "liftProgression",
        title: "Lift progression",
        tagline: "Your estimated one-rep max for a lift, session by session — are you getting stronger?",
        formula: "e1RM = weight × (1 + reps ⁄ 30)",
        sections: [
            S(heading: "How we work it out", body: "For each session we take your best working set of the lift and estimate the most you could do for a single rep, using the Epley formula. Charting that per session turns 'I lifted 100 kg for 5' into a clean strength curve."),
            S(heading: "Why an estimate", body: "A true one-rep maximum is demanding and impractical to test often. An estimate from ordinary working sets makes repeated comparison possible without requiring a maximal attempt."),
            S(heading: "How to read it", body: "Compare the same lift, technique, and rep range over time. A rising estimate can support a strength-progress trend; day-to-day changes and formula error mean one value is not a verdict."),
        ],
        source: MetricExplainer.Source("Epley B. Poundage Chart. Boyd Epley Workout, 1985. Accuracy: Reynolds JM, et al. J Strength Cond Res. 2006;20(3):584–592.", "https://pubmed.ncbi.nlm.nih.gov/16937961/"))

    static let trainingVolume = E(
        id: "trainingVolume",
        title: "Training volume",
        tagline: "Total weight you moved each week on your working sets.",
        formula: "volume = Σ (weight × reps)",
        sections: [
            S(heading: "How we work it out", body: "For every completed working set we multiply weight by reps and add it all up across the week. Warm-ups don't count — this is the meaningful work."),
            S(heading: "Why it matters", body: "Volume describes how much resistance work was recorded. It is one training-dose measure; exercise choice, load, proximity to failure, technique, and recovery also shape the response."),
            S(heading: "How to read it", body: "Compare similar training blocks rather than forcing the line upward every week. A planned lighter week or different exercise selection can lower volume without meaning progress stopped."),
        ],
        source: MetricExplainer.Source("Schoenfeld BJ, Ogborn D, Krieger JW. Dose-response relationship between weekly resistance training volume and increases in muscle mass. J Sports Sci. 2017;35(11):1073–1082.", "https://pubmed.ncbi.nlm.nih.gov/27433992/"))

    static let muscleBalance = E(
        id: "muscleBalance",
        title: "Muscle balance",
        tagline: "Which muscles your recent lifting actually worked — and which you've been skipping.",
        formula: "sets = primary × 1.0 + secondary × 0.5",
        sections: [
            S(heading: "How we work it out", body: "Across the last four weeks we tally working sets by muscle. A primary muscle gets full credit and a listed secondary muscle gets half; this is Momentum's consistent bookkeeping rule, not a physiological measurement."),
            S(heading: "Why it matters", body: "The view shows which supporting strength areas the program has emphasized. It cannot diagnose an imbalance or predict pain or injury."),
            S(heading: "How to read it", body: "Use the bars to review program coverage with exercise quality, running demands, and your goals. Do not add work automatically just to make every bar equal."),
        ],
        source: MetricExplainer.Source("Schoenfeld BJ, Ogborn D, Krieger JW. Dose-response relationship between weekly resistance training volume and increases in muscle mass. J Sports Sci. 2017;35(11):1073–1082.", "https://pubmed.ncbi.nlm.nih.gov/27433992/"))

    // MARK: Shared endurance charts (weekly distance / pace / recovery form)

    static let weeklyDistance = E(
        id: "weeklyDistance",
        title: "Weekly distance",
        tagline: "How far you ran each week — the simplest measure of endurance volume.",
        sections: [
            S(heading: "How we work it out", body: "We add up the GPS distance of every run inside each rolling seven-day window, so the most recent bar always reflects your last week of training."),
            S(heading: "How to read it", body: "Use the trend to understand running exposure and plan progression. Larger changes deserve context, but distance alone cannot predict adaptation or injury."),
        ])

    static let weeklyPace = E(
        id: "weeklyPace",
        title: "Weekly pace",
        tagline: "Your distance-weighted average running pace, week by week.",
        sections: [
            S(heading: "How we work it out", body: "For each week we average your running pace, weighted by distance so a long run counts more than a short one. Strength and other sports don't affect it."),
            S(heading: "How to read it", body: "Average pace changes with session mix, route, weather, and terrain. Compare like with like and use race or benchmark results for performance conclusions; a slower easy-heavy week can be exactly on plan."),
        ])

    static let recoveryForm = E(
        id: "recoveryForm",
        title: "Load change",
        tagline: "How your last seven days compare with your recent training pattern.",
        formula: "ratio = last 7 days ÷ recent weekly average",
        sections: [
            S(heading: "How we work it out", body: "We compare the load from your last seven days with the average week in your recent 28-day pattern. A ratio near 1 means the totals are similar; above 1 means the latest week was larger."),
            S(heading: "How to read it", body: TrainingLoadContext.methodExplanation),
        ],
        footnote: "Training context, not a medical or injury-risk score.",
        source: MetricExplainer.Source("Impellizzeri FM, et al. Acute:Chronic Workload Ratio: Conceptual Issues and Fundamental Pitfalls. Int J Sports Physiol Perform. 2020;15(6):907–913.", "https://pubmed.ncbi.nlm.nih.gov/32502973/"))

    // MARK: Recovery hub (the §7 copy deck — RECOVERY-HUB-PLAN.md)

    /// Standing footnote on every recovery-hub sheet.
    private static let healthFootnote =
        "Guidance, never a diagnosis — if something feels wrong, talk to a professional."

    static let readiness = E(
        id: "readiness",
        title: "Readiness",
        tagline: "A provisional summary of today's available recovery context.",
        formula: "Context index = weighted blend of available signals and your check-in.",
        sections: [
            S(heading: "What it is", body: "A 0–100 product index built from the signals available today: personal HRV and resting-heart-rate trends, sleep, recent training demand, and your check-in. Missing inputs are not treated as bad scores."),
            S(heading: "Why it matters", body: "Several signals moving together can prompt a closer look at how the planned session fits today. The index is low-confidence context, not a measurement of recovery and not permission to train harder."),
            S(heading: "What moves it", body: "Training, sleep, stress, travel, alcohol, illness, measurement timing, and device noise can all change the inputs. One score never clears or cancels a session on its own."),
        ],
        footnote: "A coaching-context index — not a diagnosis, recovery measurement, or clearance test.")

    static let hrv = E(
        id: "hrv",
        title: "HRV (heart-rate variability)",
        tagline: "Night-to-night variation between heartbeats, compared with your own trend.",
        sections: [
            S(heading: "What it is", body: "Variation in the time between heartbeats. Momentum reads permitted Apple Health samples and compares recent values with your personal history when enough data exists."),
            S(heading: "Why it matters", body: "HRV can add context about autonomic response when its trend is interpreted consistently. It varies widely between people and cannot diagnose recovery, illness, or training capacity."),
            S(heading: "What moves it", body: "Training, sleep, stress, alcohol, illness, breathing, measurement time, posture, and device method can all affect HRV. Read repeated trends with your check-in, not as a stand-alone verdict."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Plews DJ, et al. Training adaptation and heart rate variability in elite endurance athletes. Sports Med. 2013;43(9):773–781.", "https://pubmed.ncbi.nlm.nih.gov/23852425/"))

    static let restingHR = E(
        id: "restingHR",
        title: "Resting heart rate",
        tagline: "Your resting heart-rate trend against your own recent baseline.",
        sections: [
            S(heading: "What it is", body: "The resting-heart-rate samples available through Apple Health, shown against your own recent pattern when enough consistent data exists."),
            S(heading: "Why it matters", body: "Longer-term changes can accompany aerobic adaptation, while shorter changes can add recovery context. A deviation is nonspecific and does not identify fatigue, dehydration, illness, or fitness by itself."),
            S(heading: "What moves it", body: "Training, sleep, stress, heat, hydration, alcohol, illness, medication, measurement timing, and device method can all affect the value."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Buchheit M. Monitoring training status with HR measures: do all roads lead to Rome? Front Physiol. 2014;5:73.", "https://pubmed.ncbi.nlm.nih.gov/24578692/"))

    static let respiratoryRate = E(
        id: "respiratoryRate",
        title: "Respiratory rate",
        tagline: "Breaths per minute during sleep, compared with your own trend.",
        sections: [
            S(heading: "What it is", body: "How many breaths you take per minute while asleep."),
            S(heading: "Why it matters", body: "Respiratory rate can be relatively stable within one person, so repeated deviations may add context. A wearable estimate cannot detect illness or explain why the value changed."),
            S(heading: "What moves it", body: "Sleep stage, altitude, environment, congestion, training, illness, medication, and measurement quality can all affect the estimate."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Samaras A, et al. The Apple Watch and health monitoring: a living systematic review. npj Digital Medicine. 2024.", "https://pmc.ncbi.nlm.nih.gov/articles/PMC12823594/"))

    static let wristTemperature = E(
        id: "wristTemperature",
        title: "Wrist temperature",
        tagline: "Last night's skin temperature against your own baseline.",
        sections: [
            S(heading: "What it is", body: "How far your overnight skin temperature sat from your personal baseline."),
            S(heading: "Why it matters", body: "Wrist skin temperature is not core body temperature. Repeated deviations can add context when read with other signals, but they cannot detect illness or explain a change."),
            S(heading: "What moves it", body: "Room temperature, watch fit, sleep environment, alcohol, late exercise, illness, and menstrual-cycle variation can all affect the reading."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Samaras A, et al. The Apple Watch and health monitoring: a living systematic review. npj Digital Medicine. 2024.", "https://pmc.ncbi.nlm.nih.gov/articles/PMC12823594/"))

    static let walkingHR = E(
        id: "walkingHR",
        title: "Walking heart rate",
        tagline: "Average heart rate during ordinary walking, against your own trend.",
        sections: [
            S(heading: "What it is", body: "The average heart rate of your ordinary daily walking — no workouts, just life. A worn Apple Watch measures it quietly across the day."),
            S(heading: "Why it matters", body: "A repeated change can add context about the cost of everyday movement. It is not a direct fitness, fatigue, or illness measure, and walking pace or terrain may explain the difference."),
            S(heading: "What moves it", body: "Walking pace, hills, heat, hydration, stress, training, illness, medication, sensor fit, and aerobic adaptation can all affect it. Compare your own similar days."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Buchheit M. Monitoring training status with HR measures: do all roads lead to Rome? Front Physiol. 2014;5:73.", "https://pubmed.ncbi.nlm.nih.gov/24578692/"))

    static let sleepStages = E(
        id: "sleepStages",
        title: "Sleep stages (core, deep, REM)",
        tagline: "A wearable estimate of how the night split between core, deep, and REM.",
        sections: [
            S(heading: "What it is", body: "The three kinds of work your brain and body cycle through at night — light (core), deep, and REM."),
            S(heading: "Why it matters", body: "Sleep supports physical and cognitive recovery, but consumer wearables estimate stages rather than measuring them like a sleep laboratory. Total duration and repeated patterns are generally more actionable than one stage value."),
            S(heading: "What moves it", body: "Sleep timing, alcohol, caffeine, stress, environment, training, and the device's classification algorithm can all change the reported split."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Walsh NP, et al. Sleep and the athlete: narrative review and 2021 expert consensus recommendations. Br J Sports Med. 2021;55:356–368.", "https://pubmed.ncbi.nlm.nih.gov/33144349/"))

    static let sleepDuration = E(
        id: "sleepDuration",
        title: "Sleep duration",
        tagline: "Estimated hours asleep each night, read as a trend.",
        sections: [
            S(heading: "What it is", body: "Estimated time asleep from permitted Apple Health samples. Momentum de-duplicates overlapping sources so a minute is not intentionally counted twice; device estimates can still be imperfect."),
            S(heading: "Why it matters", body: "Sleep supports the repair, glycogen restoration, and learning that training depends on. Across weeks, the trend matters more than any single night; repeated short nights can leave recovery and hard-session quality lagging."),
            S(heading: "How to read it", body: "Look for your steady level and how it holds through hard training blocks. One short night is noise; a drifting average is a signal worth acting on. Longer windows average by week, so the value keeps its per-night meaning."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Walsh NP, et al. Sleep and the athlete: narrative review and 2021 expert consensus recommendations. Br J Sports Med. 2021;55:356–368.", "https://pubmed.ncbi.nlm.nih.gov/33144349/"))

    static let sleepDebt = E(
        id: "sleepDebt",
        title: "Sleep debt",
        tagline: "Momentum's rolling gap between estimated sleep and your selected target.",
        sections: [
            S(heading: "What it is", body: "A product estimate that adds the difference between recorded sleep and your target across the last two weeks. It is not a clinical measure of sleep need."),
            S(heading: "Why it matters", body: "Repeated short nights can affect attention, mood, and training response. The chart makes the pattern visible without claiming an exact amount of recovery owed."),
            S(heading: "What moves it", body: "Recorded nightly duration and your selected target move the value. Missing or inaccurate wearable data can also change the estimate."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Walsh NP, et al. Sleep and the athlete: narrative review and 2021 expert consensus recommendations. Br J Sports Med. 2021;55:356–368.", "https://pubmed.ncbi.nlm.nih.gov/33144349/"))

    static let sleepConsistency = E(
        id: "sleepConsistency",
        title: "Sleep consistency",
        tagline: "How repeatable your bed and wake times are, night over night.",
        sections: [
            S(heading: "What it is", body: "How closely your bed and wake times repeat, night over night."),
            S(heading: "Why it matters", body: "Regular sleep timing can support sleep quality and circadian alignment. Duration, environment, health, work, and individual needs still matter, so consistency is one part of the picture."),
            S(heading: "What moves it", body: "Changes in bedtime and wake time move the score. Shift work, travel, caregiving, and missing device data can make the pattern less regular without implying a training failure."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Walsh NP, et al. Sleep and the athlete: narrative review and 2021 expert consensus recommendations. Br J Sports Med. 2021;55:356–368.", "https://pubmed.ncbi.nlm.nih.gov/33144349/"))

    static let strain = E(
        id: "strain",
        title: "Strain",
        tagline: "Today's estimated training and movement demand in one number.",
        sections: [
            S(heading: "What it is", body: "A product estimate that combines recorded workout load with available everyday movement. It summarizes demand; it does not measure tissue stress or fatigue directly."),
            S(heading: "Why it matters", body: "The estimate helps compare easy and demanding days using one consistent method. Use it to see the shape of the week, alongside session purpose and how your body responds."),
            S(heading: "What moves it", body: "Workout duration and effort move it most; available daily movement adds context. Heat, hills, and other conditions may make the same numerical estimate feel different."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Foster C, et al. A new approach to monitoring exercise training. J Strength Cond Res. 2001;15(1):109–115.", "https://pubmed.ncbi.nlm.nih.gov/11708692/"))

    static let strainRecoveryBalance = E(
        id: "strainRecoveryBalance",
        title: "Strain–recovery balance",
        tagline: "Training demand and recovery context, side by side.",
        sections: [
            S(heading: "What it is", body: "Two imperfect context curves: recent training demand and the recovery signals available from your check-ins and connected health data."),
            S(heading: "Why it matters", body: "Neither curve diagnoses readiness or predicts injury. A persistent mismatch is a prompt to review sleep, stress, illness, pain, and how the sessions actually feel before deciding whether the plan still fits."),
            S(heading: "What moves it", body: "Training changes the strain curve. Sleep, stress, illness, travel, alcohol, and measurement noise can all move recovery signals. We act conservatively when several inputs and your own response agree."),
        ],
        footnote: "Context for a coaching conversation — not a diagnosis, injury-risk score, or clearance test.")

    static let restDays = E(
        id: "restDays",
        title: "Rest days",
        tagline: "Planned lower-demand days that make the training week sustainable.",
        sections: [
            S(heading: "What it is", body: "Planned days of little or no training — a scheduled part of the program, not a hole in it."),
            S(heading: "Why it matters", body: "Lower-demand days create room to recover between training exposures and are an intentional part of the plan. More work is not automatically better, and a rest day is not missed training."),
            S(heading: "What moves it", body: "Nothing to optimize — take them as planned. A kept rest day counts toward your streak, and your rhythm chart wears it proudly."),
        ],
        footnote: healthFootnote,
        source: MetricExplainer.Source("Kellmann M, et al. Recovery and performance in sport: consensus statement. Int J Sports Physiol Perform. 2018;13(2):240–245.", "https://pubmed.ncbi.nlm.nih.gov/29345524/"))

    static let whereDataComesFrom = E(
        id: "whereDataComesFrom",
        title: "Where this data comes from",
        tagline: "Permitted signals arrive through Apple Health and are compared with your own history.",
        sections: [
            S(heading: "One door: Apple Health", body: "Momentum reads supported signal types from Apple Health only when you grant permission and another device or app has written them there. Connecting never imports workout history or creates Momentum workouts."),
            S(heading: "Available signals", body: "Sleep, HRV, resting heart rate, and overnight vitals usually require a compatible watch or ring configured to write those specific values to Apple Health. Without them, the context index uses fewer inputs and says so."),
            S(heading: "Your own history", body: "Bands compare with your personal history when enough consistent data exists. They are descriptive ranges, not population rankings, diagnoses, or training clearance."),
        ],
        footnote: healthFootnote)

    static let dailySteps = E(
        id: "dailySteps",
        title: "Daily movement",
        tagline: "Everyday movement recorded between planned workouts.",
        sections: [
            S(heading: "What it is",
              body: "Total steps per day, read from Apple Health — phone and watch combined, de-duplicated. Training shows up as peaks; this is the base underneath them."),
            S(heading: "Why it matters for endurance",
              body: "Daily movement adds context around planned training. A change may reflect schedule, travel, rest, device wear, or how you feel; it does not diagnose fatigue or recovery."),
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
