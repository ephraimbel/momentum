import Foundation

/// The workout library (2026-07-23): the sport's canonical quality sessions as a browsable,
/// personalized catalog. Every entry compiles to the SAME `PlannedSession` grammar the plan
/// generator writes — so a picked workout previews, guides, adapts, and scores exactly like a
/// plan-prescribed one (`StructuredWorkoutBuilder` is the single expansion path, PRD §4.3).
///
/// Curation rules:
///  • Canon only — each entry is a session coaches have prescribed for decades (VO₂ repeats,
///    threshold cruise work, fartlek, hill strength, progressions), not app inventions.
///  • Personalized, never generic — paces derive from the athlete's calibrated 5k through the
///    same Daniels/VDOT ladder the plan uses. The library never invents a number.
///  • One honest volume dial per workout, bounded to coach-sane ranges — an athlete can size a
///    session, not distort it.
///  • The prose IS the coach: what/why/how-it-feels/execution cues are written to be read aloud.
///
/// Pure and deterministic; SwiftData session creation lives with the UI.
enum WorkoutLibrary {

    // MARK: Taxonomy

    enum Category: String, CaseIterable, Identifiable {
        case speed = "Speed"
        case threshold = "Threshold"
        case fartlek = "Fartlek"
        case hills = "Hills"
        case endurance = "Endurance"
        case foundations = "Foundations"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .speed: "bolt.fill"
            case .threshold: "gauge.with.needle"
            case .fartlek: "wind"
            case .hills: "mountain.2.fill"
            case .endurance: "arrow.up.right"
            case .foundations: "figure.walk"
            }
        }

        /// One line on what this family of sessions builds — the section subtitle.
        var blurb: String {
            switch self {
            case .speed: "Top-end aerobic power. Short, fast, fully recovered."
            case .threshold: "Raise the pace you can hold. The biggest lever for race times."
            case .fartlek: "Speed play — structure without the track. Effort over numbers."
            case .hills: "Strength you can run on. The gym, disguised as a run."
            case .endurance: "Go longer, finish stronger. Where races are actually won."
            case .foundations: "Form and first steps. Where every runner starts — and returns."
            }
        }
    }

    enum Tier: String, CaseIterable {
        case beginner = "Beginner"
        case intermediate = "Intermediate"
        case advanced = "Advanced"
    }

    /// The one volume control an entry exposes. Values are coach-sane bounds, never a free field.
    enum Dial: Equatable {
        case reps([Int], defaultReps: Int)
        /// Total session distance in km (snapped to clean per-unit values at prescription time).
        case kilometers([Double], defaultKm: Double)
        /// Total session minutes (run/walk).
        case minutes([Double], defaultMin: Double)
    }

    /// The structural skeleton — everything needed to write the session grammar.
    enum Structure: Equatable {
        case distanceReps(repM: Double, note: String)   // note: "@ VO2" or "@ 5K" — prices the reps
        case timeReps(repMin: Double)                   // "@ VO2"
        case cruiseReps(repM: Double)                   // "@ threshold" → 60 s floats downstream
        case fartlek(onS: Double, floatS: Double)
        case hills(pushS: Double)
        case strides(strideS: Double, count: Int)       // km dial sizes the easy bulk
        case tempo
        case progression
        case raceFinishLong(finishKm: Double)
        case runWalk(runMin: Double, walkMin: Double)
    }

    // MARK: Entry

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let category: Category
        let tier: Tier
        let structure: Structure
        let dial: Dial
        /// What you'll do — one plain sentence.
        let what: String
        /// The physiology, honestly and without a lecture.
        let why: String
        /// What the effort should feel like — the calibration a coach gives you at the track.
        let feels: String
        /// Execution cues, written to be spoken. 2–4 short lines.
        let execution: [String]
        /// The one-line why stored on the session (`rationale`) — Plan/Today read it back.
        let rationale: String
    }

    // MARK: Catalog

    static let all: [Entry] = [

        // ── SPEED ────────────────────────────────────────────────────────────────────────────

        Entry(id: "reps-400", name: "400m repeats", category: .speed, tier: .beginner,
              structure: .distanceReps(repM: 400, note: "@ VO2"),
              dial: .reps([6, 8, 10, 12], defaultReps: 8),
              what: "Short fast repeats — one lap of a track — with a slow jog between each.",
              why: "Two minutes is long enough to push your aerobic ceiling and short enough that your form never falls apart. This is the classic first speed session: it teaches your legs what fast feels like while the jog recoveries keep every rep honest.",
              feels: "Hard but controlled — about the effort you could race for 12–15 minutes. The last two reps should feel like work; the first two should feel almost easy. If rep one feels hard, you started too fast.",
              execution: ["Run the first rep slightly slower than you think you should.",
                          "Jog the recoveries — walking resets too much, standing resets nothing.",
                          "Same pace every rep. Even is the win, not fast.",
                          "If your form breaks — shoulders up, stride shortening — end the session. That rep was the last useful one."],
              rationale: "Short VO₂ repeats build top-end aerobic power while keeping each fast effort brief — a controlled entry to speed work."),

        Entry(id: "reps-800", name: "800m repeats", category: .speed, tier: .intermediate,
              structure: .distanceReps(repM: 800, note: "@ 5K"),
              dial: .reps([4, 5, 6, 8], defaultReps: 5),
              what: "Two-lap repeats at your 5K race pace, with a couple of minutes of jogging between.",
              why: "800s at 5K pace are the bridge between speed and racing: long enough to rehearse race rhythm, short enough to hold perfect form. Stack a few weeks of these and 5K pace stops feeling like an event.",
              feels: "Exactly your 5K race effort — quick but sustainable, breathing hard by the end of each rep and recovered enough to repeat it. Not a sprint. Ever.",
              execution: ["Lock into goal pace in the first 100 meters — don't sprint the start and hang on.",
                          "Think rhythm, not speed. You're rehearsing the race.",
                          "Halfway through the set, check in: could you do one more than planned? That's the right effort."],
              rationale: "Race-pace 800s rehearse 5K rhythm — the classic predictor session that makes goal pace familiar."),

        Entry(id: "yasso-800", name: "Yasso 800s", category: .speed, tier: .intermediate,
              structure: .distanceReps(repM: 800, note: "@ 5K"),
              dial: .reps([6, 8, 10], defaultReps: 8),
              what: "800m repeats with a 400m jog between, built up week by week toward ten of them.",
              why: "Bart Yasso's session became famous for a rule of thumb: run ten 800s in the same minutes-and-seconds as your goal marathon in hours-and-minutes, and the marathon is in range. Treat the prediction as folklore and the workout as gold. Ten hard 800s off short jogs is a genuine test of aerobic strength and of your willingness to keep the last three honest.",
              feels: "Each rep is controlled, not raced. Reps one through four should feel almost restrained; the session is decided in the last three, where holding pace stops being physical and starts being a choice.",
              execution: ["Even splits are the entire point. A fast first rep invalidates the whole set.",
                          "Jog the 400 between. Standing around turns the session into a workout you can fake.",
                          "Build the count across a block: start at six and add a rep every week or two.",
                          "If reps eight to ten drift more than a few seconds, you sized the pace too fast, not the session too long."],
              rationale: "The marathoner's benchmark session: even 800s off short jogs test aerobic strength and pace discipline together."),

        Entry(id: "reps-1k", name: "1K repeats", category: .speed, tier: .advanced,
              structure: .distanceReps(repM: 1000, note: "@ VO2"),
              dial: .reps([3, 4, 5, 6], defaultReps: 4),
              what: "Kilometer repeats at interval effort with three minutes of jogging between.",
              why: "Three-to-four-minute repeats keep oxygen demand high through much of each rep. They are a potent distance-running session, so the recoveries and total dose matter.",
              feels: "The first minute feels comfortable, the second honest, the third like the point of the session. You should finish each rep certain you could run one more lap — barely.",
              execution: ["Even pace within each rep — no first-200 heroics.",
                          "Use the full recovery. Jog it slow; the next rep is the workout, not the rest.",
                          "Cut the session, not the pace: three good reps beat five ragged ones."],
              rationale: "3–4 minute VO₂ repeats are the highest-value ceiling-raiser in distance running."),

        Entry(id: "reps-1200", name: "1200m repeats", category: .speed, tier: .advanced,
              structure: .distanceReps(repM: 1200, note: "@ VO2"),
              dial: .reps([3, 4, 5, 6], defaultReps: 4),
              what: "Three-lap repeats at interval effort with a full three minutes of jogging between.",
              why: "Four to five minutes is the longest a body holds true VO₂max, which makes the 1200 the most time-efficient rep distance in the sport: almost the entire repeat is spent at the ceiling you are trying to raise. Daniels built the classic I-pace session around this distance, and it has been the backbone of 5K and 10K training ever since.",
              feels: "Committed from the first stride and honest by the third lap. You should be counting laps, not seconds. Finish each rep able to start the next one after the jog, and no sooner.",
              execution: ["Take the full three minutes. Cutting the jog turns an interval session into a bad tempo.",
                          "Even laps within the rep. The classic error is a fast first lap that costs you the third.",
                          "Cap the total work at about five kilometres of reps. Past that the quality goes and the cost stays.",
                          "Two ragged reps at the end teach nothing. End the set while it is still sharp."],
              rationale: "Four-to-five-minute reps hold true VO₂max longer than any other distance, which is why they anchor 5K and 10K blocks."),

        Entry(id: "reps-mile", name: "Mile repeats", category: .speed, tier: .advanced,
              structure: .distanceReps(repM: 1600, note: "@ VO2"),
              dial: .reps([3, 4, 5], defaultReps: 4),
              what: "Mile repeats at interval effort, three minutes of jogging between each.",
              why: "The mile repeat is the session distance runners measure themselves by. It is long enough that pacing judgment matters as much as fitness, and it rehearses the specific discomfort of the middle of a 10K, where the effort is set and the only question left is whether you hold it. Every serious 10K and half build has these in it somewhere.",
              feels: "Settled, strong, and slightly relentless. The second half of each rep is the session. If the first mile felt easy and the last one felt survivable, you paced it correctly.",
              execution: ["Run the first rep at the pace you intend to run the last one. That is the whole discipline.",
                          "Split each mile in halves and compare. Even beats fast every single time.",
                          "Three minutes of jogging, moving the whole time.",
                          "Four honest miles is a serious session. There is no prize for a fifth ragged one."],
              rationale: "Long VO₂ reps rehearse the middle of a 10K, where pacing judgment matters as much as fitness."),

        Entry(id: "reps-3min", name: "3-minute repeats", category: .speed, tier: .intermediate,
              structure: .timeReps(repMin: 3),
              dial: .reps([4, 5, 6], defaultReps: 5),
              what: "Three minutes hard, three minutes easy — no track, no measuring, anywhere.",
              why: "The time-based VO₂ session: identical stimulus to kilometer repeats, zero geography required. Roads, trails, treadmill — the watch does the measuring so you can run by effort where there are no lap lines.",
              feels: "Build to hard over the first 30 seconds, then hold — an effort you could sustain for about 10 minutes in a race. Terrain will move your pace around; hold the effort and let the pace be what it is.",
              execution: ["Pick a stretch without traffic lights — momentum matters here.",
                          "First 30 seconds of each rep: build in, don't launch.",
                          "On hills or wind, hold the effort and forget the pace."],
              rationale: "Time-based VO₂ repeats deliver the interval stimulus anywhere — no track required."),

        // ── THRESHOLD ────────────────────────────────────────────────────────────────────────

        Entry(id: "tempo", name: "Tempo run", category: .threshold, tier: .intermediate,
              structure: .tempo,
              dial: .kilometers([5, 6.5, 8, 10], defaultKm: 6.5),
              what: "Easy warm-up, one continuous block at threshold effort, easy cool-down.",
              why: "Threshold is the pace your body can just barely clear lactate at — run there and you push that ceiling up. Twenty-to-forty minutes at this effort is the single most reliable way to make every race pace feel easier. If you only do one quality session a week, make it this one.",
              feels: "Comfortably hard — you could say a sentence, not tell a story. About the pace you could race for a full hour. It should feel almost too easy for the first ten minutes. That's correct. Hold it.",
              execution: ["Settle in over the first kilometer — threshold found gradually is threshold held longer.",
                          "If you're gasping, you've drifted into racing. Back off two ticks.",
                          "The last kilometer should feel strong, not desperate."],
              rationale: "A continuous threshold block is the most reliable race-pace improver in the sport."),

        Entry(id: "cruise", name: "Cruise intervals", category: .threshold, tier: .intermediate,
              structure: .cruiseReps(repM: 1600),
              dial: .reps([3, 4, 5, 6], defaultReps: 4),
              what: "Mile repeats at threshold pace with only 60 seconds of jogging between.",
              why: "Cruise intervals are the tempo run's clever sibling: the short rests let you bank more total time at threshold than one continuous block, while each rep stays mentally bite-sized. The 60-second float is the point — your effort barely drops, and the fitness compounds.",
              feels: "Same comfortably-hard effort as a tempo — the minute of jogging takes the edge off without ever letting you fully recover. The set should feel like one long tempo with breathing room, not four separate races.",
              execution: ["Threshold pace, not 5K pace — the short rest punishes greed by rep three.",
                          "Keep the 60 seconds moving. A slow jog, never a stand.",
                          "Even splits across the set is the whole game."],
              rationale: "Short-rest threshold reps bank more quality volume than a single tempo block can."),

        Entry(id: "cruise-1k", name: "1K threshold reps", category: .threshold, tier: .beginner,
              structure: .cruiseReps(repM: 1000),
              dial: .reps([4, 5, 6, 8], defaultReps: 6),
              what: "Kilometre repeats at threshold pace, with only 60 seconds of jogging between.",
              why: "The friendliest way into threshold work. A kilometre is short enough that the pace never feels like a commitment you regret, and the 60-second float keeps your effort high enough that the set still behaves like one long tempo. This is where most athletes should start threshold training, and plenty of very fast ones never stop doing it.",
              feels: "Comfortably hard, and repeatable. The minute of jogging takes the edge off without ever letting you fully recover, so rep six should feel like the natural end of one continuous effort rather than a sixth separate race.",
              execution: ["Threshold, not 5K. The short float punishes an ambitious first rep by rep four.",
                          "Keep the minute moving. A jog, never a stand.",
                          "Add a rep before you add pace. Volume at threshold is the adaptation."],
              rationale: "Short threshold reps off a 60-second float are the most approachable way to bank time at threshold."),

        Entry(id: "threshold-2k", name: "2K threshold reps", category: .threshold, tier: .advanced,
              structure: .cruiseReps(repM: 2000),
              dial: .reps([3, 4, 5], defaultReps: 3),
              what: "Two-kilometre blocks at threshold pace off a 60-second float.",
              why: "Long threshold reps ask for everything a tempo does and then ask you to do it again. Splitting the work into 2K blocks lets you hold true threshold for far longer than a single continuous effort would allow, which is exactly the point: the adaptation follows total time at the pace, and the float is short enough that your body barely notices the seam.",
              feels: "The same comfortably-hard effort as a tempo, sustained past the point where it stops being interesting. The final rep should be the one you are proudest of, run at the same pace as the first.",
              execution: ["Settle in over the first 400 of each rep. Threshold found gradually is threshold held.",
                          "The 60 seconds is a float, not a rest. Keep it honest and keep it short.",
                          "If rep three is slower than rep one, the pace was wrong. Note it and price the next one properly."],
              rationale: "Long threshold blocks bank more time at threshold than a single tempo can, which is where the adaptation lives."),

        // ── FARTLEK ──────────────────────────────────────────────────────────────────────────

        Entry(id: "fartlek-classic", name: "Classic fartlek", category: .fartlek, tier: .beginner,
              structure: .fartlek(onS: 60, floatS: 60),
              dial: .reps([6, 8, 10, 12], defaultReps: 8),
              what: "One minute strong, one minute easy, repeated — speed play on any route.",
              why: "Fartlek is Swedish for speed play, and play is the point: real speed work with no track, no lap pressure, no failed splits. The surges build power and pace-changing ability; the floats teach you to recover while still running — the skill every race actually demands.",
              feels: "Surges around your 3K-to-5K effort — strong, not sprinting. Floats at a genuinely easy jog, not a walk. By the last few, the floats will feel short. They're supposed to.",
              execution: ["Surge to a landmark mentality — strong and smooth, not flat-out.",
                          "The float is a jog. Keep your feet turning over.",
                          "Nobody's timing your splits. Run strong, run playful."],
              rationale: "Surge-and-float running builds speed and the race skill of recovering on the move."),

        Entry(id: "fartlek-3030", name: "30-30s", category: .fartlek, tier: .beginner,
              structure: .fartlek(onS: 30, floatS: 30),
              dial: .reps([10, 12, 16, 20], defaultReps: 12),
              what: "30 seconds quick, 30 seconds easy, repeated — the gentlest doorway into speed.",
              why: "Half a minute is short enough that anyone can run fast for it, and the equal float keeps your oxygen system working at near-full output the whole set — big aerobic stimulus, small dose of strain per rep. This is the session sports science keeps validating and coaches keep prescribing to newer runners.",
              feels: "Quick but relaxed — around the pace you could race for 10–12 minutes. The magic is in the accumulation, not any single rep. If you need to bend over between reps, ease the surges.",
              execution: ["Fast and light — think quick feet, tall posture.",
                          "Keep the floats honest: slow jog, never stopped.",
                          "The set works as a whole. No hero reps."],
              rationale: "Short equal-float surges deliver a big aerobic stimulus in small, low-risk doses."),

        Entry(id: "fartlek-surges", name: "Long surges", category: .fartlek, tier: .intermediate,
              structure: .fartlek(onS: 120, floatS: 120),
              dial: .reps([4, 5, 6, 8], defaultReps: 6),
              what: "Two minutes strong, two minutes easy — sustained surges that build racing strength.",
              why: "Two-minute surges live between speed and threshold: long enough to demand sustained focus, forgiving enough to recover from. This is where you learn to inject a move mid-race — and to settle back down after one without falling apart.",
              feels: "Strong and gathered — around 5K effort, held with intent. The float should be a real reset: first 30 seconds slow, then building back to an easy rhythm before the next surge.",
              execution: ["Commit to each surge from the first stride — gather, go, settle.",
                          "Use the full float. Discipline in the easy halves makes the hard halves count.",
                          "Last surge strongest. Finish the set proud of it."],
              rationale: "Sustained surges rehearse mid-race moves — pressing, then recovering without unraveling."),

        // ── HILLS ────────────────────────────────────────────────────────────────────────────

        Entry(id: "hills-short", name: "Short hill sprints", category: .hills, tier: .intermediate,
              structure: .hills(pushS: 30),
              dial: .reps([6, 8, 10, 12], defaultReps: 8),
              what: "30-second strong pushes up a hill, jogging back down between each.",
              why: "A hill is a weight room that doesn't need a membership: every stride uphill loads your glutes, calves, and hamstrings against gravity with almost no impact cost. Short hill work builds the raw strength that later turns into flat speed — and it's one of the safest hard sessions in running.",
              feels: "Strong, driving effort — about 90% — with power coming from your hips. You should reach the top working hard but tall. The jog down is the recovery; take all of it.",
              execution: ["Find a steady 4–6% grade — challenging, still runnable.",
                          "Drive your knees, pump your arms, keep your chest up the whole climb.",
                          "Effort over pace — the hill sets the numbers, you set the intent.",
                          "Jog down slower than feels natural. Gravity did enough work already."],
              rationale: "Uphill pushes build running-specific strength with a fraction of the impact of flat speed."),

        Entry(id: "hills-sprint", name: "10-second hill sprints", category: .hills, tier: .beginner,
              structure: .hills(pushS: 10),
              dial: .reps([6, 8, 10, 12], defaultReps: 8),
              what: "Ten seconds of maximal uphill running, with a full walk-and-jog recovery between each.",
              why: "Ten seconds is too short to accumulate any real fatigue, which is exactly why this works. You get a pure neuromuscular stimulus, maximum fibre recruitment against gravity, at close to zero aerobic cost and with almost no injury risk. Coaches slot these onto easy days year-round because they build power and stiffness without touching the week's hard-day budget.",
              feels: "All-out for ten seconds, and then genuinely finished. This is not a hard session and should never leave you tired. If you are breathing hard between reps, you are taking too little recovery.",
              execution: ["Find a steep hill, steeper than you would use for repeats. Grade is the resistance.",
                          "Maximal from the first stride. There is no pacing a ten-second effort.",
                          "Walk back down and take two to three minutes. Full recovery is the prescription, not a luxury.",
                          "Stop the moment any rep is slower than the ones before it. Power work ends before fatigue starts."],
              rationale: "Ten-second maximal climbs build power and tendon stiffness at almost no aerobic or recovery cost."),

        Entry(id: "hills-long", name: "Hill repeats", category: .hills, tier: .intermediate,
              structure: .hills(pushS: 75),
              dial: .reps([4, 6, 8, 10], defaultReps: 6),
              what: "75-second climbs at a strong effort, easy jog back down between.",
              why: "Longer climbs shift the stimulus from pure strength toward strength-endurance — holding power output while fatigue builds. This is the session that makes the last hill of a race feel like a place you've been before, because you have.",
              feels: "Honest, sustained work — around your 10-minute race effort against the grade. The last 15 seconds of each climb is where the session lives. Stay tall through it.",
              execution: ["Settle into a rhythm you can hold to the top — surging early is borrowing.",
                          "Shorten your stride as the grade demands; keep the cadence.",
                          "Run through the crest, not to it. Races don't end at the bottom of hills."],
              rationale: "Sustained climbs build the strength-endurance that holds form deep into a race."),

        Entry(id: "hills-3min", name: "Long hill climbs", category: .hills, tier: .advanced,
              structure: .hills(pushS: 180),
              dial: .reps([4, 5, 6], defaultReps: 5),
              what: "Three-minute climbs at a strong sustained effort, jogging down between each.",
              why: "A three-minute climb is a VO₂ interval that the hill polices for you: the grade makes going out too fast physically impossible and makes holding form the entire task. You get the aerobic stimulus of a kilometre repeat with markedly less impact, which is why coaches lean on long climbs in early build phases and for athletes coming back from a niggle.",
              feels: "Around your 10-minute race effort, held against the grade. The last 45 seconds of each climb is where the session lives. Stay tall through it and let the pace be whatever the hill decides.",
              execution: ["Pick a climb you can run for three minutes without the grade breaking your stride.",
                          "Shorten the stride, keep the cadence, drive the arms. Posture is the workout.",
                          "Jog all the way back down. The descent is recovery, never a second effort.",
                          "Run through the crest on the last one. Races do not end at the top of hills."],
              rationale: "Long climbs deliver a VO₂ stimulus with far less impact, and the grade enforces the pacing for you."),

        // ── ENDURANCE ────────────────────────────────────────────────────────────────────────

        Entry(id: "progression", name: "Progression run", category: .endurance, tier: .intermediate,
              structure: .progression,
              dial: .kilometers([6, 8, 10, 12], defaultKm: 8),
              what: "One continuous run in three gears: easy, then steady, then strong.",
              why: "Finishing faster than you started teaches the exact skill racing demands — pushing on legs that already have miles in them. The three-gear ladder (easy → marathon effort → threshold) builds that ability progressively, inside a single controlled run. Kenyan training groups have made this their daily bread for a reason.",
              feels: "The first third almost frustratingly easy. The middle third is purposeful — marathon effort, breathing deeper but in control. The final third is strong: comfortably hard, finishing with intent, never a sprint.",
              execution: ["Discipline in the first third IS the workout. Hold back.",
                          "Change gears decisively at each third — settle into the new effort within a minute.",
                          "The last kilometer should be your fastest, and it should feel earned, not desperate."],
              rationale: "Finishing faster than you start trains the race's real demand: strength on tired legs."),

        Entry(id: "long-racefinish", name: "Race-pace finish long run", category: .endurance, tier: .advanced,
              structure: .raceFinishLong(finishKm: 5),
              dial: .kilometers([14, 16, 19, 22], defaultKm: 16),
              what: "A steady long run that closes with its final 5K at your goal race pace.",
              why: "Anyone can run race pace fresh. Running it after 90 minutes on your feet — with glycogen low and form fraying — is the actual job on race day, and this is the only session that rehearses it honestly. The signature workout of every serious marathon build.",
              feels: "The steady body should feel almost too relaxed — that restraint is what makes the finish possible. When the race-pace block starts, expect the first kilometer to feel harder than it should. It settles. Trust it.",
              execution: ["The steady miles are the setup, not the show. Keep them genuinely steady.",
                          "Fuel early and often — this session doubles as race-day fueling rehearsal.",
                          "When the finish block starts, change gears within a minute and lock in.",
                          "Done right, you finish thinking you had one more kilometer in you."],
              rationale: "Goal pace on tired legs is race day's real demand — this is its only honest rehearsal."),

        Entry(id: "long-mp", name: "Marathon-pace long run", category: .endurance, tier: .advanced,
              structure: .raceFinishLong(finishKm: 10),
              dial: .kilometers([18, 21, 24], defaultKm: 21),
              what: "A steady long run whose final 10K is run at goal marathon pace.",
              why: "A ten-kilometre block of race pace at the end of a long run is the single most specific session in marathon training. It rehearses the exact hour of the race that decides it, teaches your body to burn fat and carbohydrate side by side at goal effort, and gives you an honest read on whether your goal pace is a plan or a wish. Canova built his marathon system on blocks like this one.",
              feels: "The steady body should feel almost too relaxed, because that restraint is what makes ten kilometres of race pace possible. The first kilometre of the block always feels harder than it should. It settles by the second. What you want at the finish is the sense you could have held it for another two.",
              execution: ["The steady miles set the session up. Run them slower than feels natural.",
                          "Fuel it exactly like the race. This is your carbohydrate rehearsal as much as your pace one.",
                          "Change gear decisively and lock in within the first kilometre of the block.",
                          "If the block falls apart past halfway, that is data about your goal pace, not a failure. Bring it to the plan."],
              rationale: "Ten kilometres at goal pace on tired legs is the most race-specific session in a marathon build."),

        // ── FOUNDATIONS ──────────────────────────────────────────────────────────────────────

        Entry(id: "strides", name: "Easy run + strides", category: .foundations, tier: .beginner,
              structure: .strides(strideS: 20, count: 6),
              dial: .kilometers([4, 5, 6.5], defaultKm: 5),
              what: "A relaxed easy run capped with six 20-second smooth accelerations.",
              why: "Strides are 20 seconds of your best form — fast but never straining — and they're how easy days quietly maintain your speed. They recruit the fast muscle fibers easy running can't reach, cost almost nothing to recover from, and over months they're the difference between a runner who ages into slowness and one who doesn't.",
              feels: "The run: genuinely easy, conversational the whole way. The strides: build to about 90% over 5 seconds, float there feeling fast and smooth, then let it go. If a stride feels like straining, it's a sprint — back it off.",
              execution: ["Keep the run truly easy — the strides are the dessert, not the meal.",
                          "Think tall, quick, relaxed. Speed should feel like falling forward, not forcing.",
                          "Walk fully between strides. This is practice, not training load."],
              rationale: "Strides keep speed and form alive on easy days at almost zero recovery cost."),

        Entry(id: "runwalk", name: "Run/walk builder", category: .foundations, tier: .beginner,
              structure: .runWalk(runMin: 2, walkMin: 1),
              dial: .minutes([20, 30, 40], defaultMin: 30),
              what: "Two minutes of easy running, one minute of walking, repeated — the proven on-ramp.",
              why: "Run/walk isn't training-lite — it's how bodies actually adapt to running's impact without breaking. The walk breaks keep your heart rate aerobic and your tissues under repairable load, which is why this method has taken more people from the couch to a finish line than any other in history.",
              feels: "The runs should feel easy enough to talk through — if you're gasping when the walk break arrives, slow the runs down, don't tough them out. The walks are brisk and purposeful, part of the workout.",
              execution: ["Slow is the strategy. The run segments should feel almost too easy.",
                          "Walk with purpose — you're recovering, not stopping.",
                          "Consistency beats duration: finishing fresh today is what gets you here Thursday."],
              rationale: "Alternating run and walk builds durable running fitness with impact your body can absorb."),
    ]

    static func entries(in category: Category) -> [Entry] {
        all.filter { $0.category == category }
    }

    static func entry(id: String) -> Entry? {
        all.first { $0.id == id }
    }

    // MARK: Prescription (entry + dial → the session grammar)

    /// Everything a `PlannedSession` needs — the same field shapes the plan generator writes.
    struct Prescription: Equatable {
        var name: String
        var runType: RunType
        var intervals: String?
        var targetDistanceM: Double?
        var targetDurationS: Double?
        var targetPaceSPerKm: Double
        var rationale: String
    }

    /// Compile an entry at a chosen dial value into the session grammar. `volume` is reps, km, or
    /// minutes per the entry's dial; nil takes the default. Paces derive from the athlete's
    /// calibrated 5k through `PlanEngine.sessionPace` — the exact rule persisted plan sessions use,
    /// so a library pick and a plan prescription can never disagree about what "@ threshold" means.
    static func prescription(_ entry: Entry, volume: Double? = nil, p5k: Double,
                             unit: DistanceUnit) -> Prescription {
        let easy = PlanEngine.pace(.easy, p5k: p5k)

        func reps(_ dial: Dial) -> Int {
            if case let .reps(options, def) = dial {
                let v = volume.map(Int.init) ?? def
                return options.contains(v) ? v : def
            }
            return 1
        }
        /// Total distance from a km dial, snapped to the clean value a coach would say out loud.
        func snappedKmM(_ dial: Dial) -> Double {
            guard case let .kilometers(options, def) = dial else { return 0 }
            let km = volume ?? def
            let bounded = options.contains(km) ? km : def
            return RunRounding.snap(meters: bounded * 1000, unit: unit)
        }
        func minutes(_ dial: Dial) -> Double {
            guard case let .minutes(options, def) = dial else { return 0 }
            let v = volume ?? def
            return options.contains(v) ? v : def
        }

        switch entry.structure {
        case let .distanceReps(repM, note):
            let n = reps(entry.dial)
            let grammar = "\(n)×\(StructuredWorkoutBuilder.repDistanceLabel(repM)) \(note)"
            let repPace = PlanEngine.sessionPace(.intervals, p5k: p5k, intervals: grammar)
            let guided = StructuredWorkoutBuilder.intervals(reps: n, repTarget: .distance(repM), repPace: repPace,
                easyPace: easy, recoveryPace: PlanEngine.pace(.recovery, p5k: p5k),
                unitLabel: StructuredWorkoutBuilder.repDistanceLabel(repM),
                recoveryOverrideS: grammar.lowercased().contains("threshold") ? 60 : nil)
            return Prescription(name: entry.name, runType: .intervals, intervals: grammar,
                                targetDistanceM: RunPrescriptionBudget.distance(guided, easyPace: easy), targetDurationS: nil,
                                targetPaceSPerKm: PlanEngine.sessionPace(.intervals, p5k: p5k, intervals: grammar),
                                rationale: entry.rationale)

        case let .timeReps(repMin):
            let n = reps(entry.dial)
            let grammar = "\(n)×\(Int(repMin))min @ VO2"
            let repS = repMin * 60
            // Warm-up/cool-down (1 km each at easy) + reps + roughly-equal-time recoveries.
            let estimate = 2 * easy + Double(n) * repS + Double(n - 1) * max(60, repS)
            return Prescription(name: entry.name, runType: .intervals, intervals: grammar,
                                targetDistanceM: nil, targetDurationS: estimate,
                                targetPaceSPerKm: PlanEngine.sessionPace(.intervals, p5k: p5k, intervals: grammar),
                                rationale: entry.rationale)

        case let .cruiseReps(repM):
            let n = reps(entry.dial)
            let grammar = "\(n)×\(StructuredWorkoutBuilder.repDistanceLabel(repM)) @ threshold"
            let repPace = PlanEngine.sessionPace(.intervals, p5k: p5k, intervals: grammar)
            let guided = StructuredWorkoutBuilder.intervals(reps: n, repTarget: .distance(repM), repPace: repPace,
                easyPace: easy, recoveryPace: PlanEngine.pace(.recovery, p5k: p5k),
                unitLabel: StructuredWorkoutBuilder.repDistanceLabel(repM), recoveryOverrideS: 60)
            return Prescription(name: entry.name, runType: .intervals, intervals: grammar,
                                targetDistanceM: RunPrescriptionBudget.distance(guided, easyPace: easy), targetDurationS: nil,
                                targetPaceSPerKm: PlanEngine.sessionPace(.intervals, p5k: p5k, intervals: grammar),
                                rationale: entry.rationale)

        case let .fartlek(onS, floatS):
            let n = reps(entry.dial)
            let grammar = "\(n)×(\(StructuredWorkoutBuilder.secLabel(onS)) hard / \(StructuredWorkoutBuilder.secLabel(floatS)) float)"
            let estimate = 2 * easy + Double(n) * (onS + floatS)
            return Prescription(name: entry.name, runType: .fartlek, intervals: grammar,
                                targetDistanceM: nil, targetDurationS: estimate,
                                targetPaceSPerKm: PlanEngine.pace(.fartlek, p5k: p5k),
                                rationale: entry.rationale)

        case let .hills(pushS):
            let n = reps(entry.dial)
            let grammar = "\(n)×\(StructuredWorkoutBuilder.secLabel(pushS)) hills"
            // The jog-down floor must match the builder's (StructuredWorkout.hills uses max(90, …))
            // or the estimated duration undercounts short hills by minutes.
            let estimate = 2 * easy + Double(n) * (pushS + max(90, pushS * 1.6))
            return Prescription(name: entry.name, runType: .hills, intervals: grammar,
                                targetDistanceM: nil, targetDurationS: estimate,
                                targetPaceSPerKm: PlanEngine.pace(.hills, p5k: p5k),
                                rationale: entry.rationale)

        case let .strides(strideS, count):
            let grammar = "\(count)×\(Int(strideS))sec strides"
            return Prescription(name: entry.name, runType: .strides, intervals: grammar,
                                targetDistanceM: snappedKmM(entry.dial), targetDurationS: nil,
                                targetPaceSPerKm: PlanEngine.pace(.strides, p5k: p5k),
                                rationale: entry.rationale)

        case .tempo:
            return Prescription(name: entry.name, runType: .tempo, intervals: nil,
                                targetDistanceM: snappedKmM(entry.dial), targetDurationS: nil,
                                targetPaceSPerKm: PlanEngine.pace(.tempo, p5k: p5k),
                                rationale: entry.rationale)

        case .progression:
            return Prescription(name: entry.name, runType: .progression, intervals: nil,
                                targetDistanceM: snappedKmM(entry.dial), targetDurationS: nil,
                                targetPaceSPerKm: PlanEngine.pace(.progression, p5k: p5k),
                                rationale: entry.rationale)

        case let .raceFinishLong(finishKm):
            let grammar = "Last \(Int(finishKm))km @ race pace"
            return Prescription(name: entry.name, runType: .long, intervals: grammar,
                                targetDistanceM: snappedKmM(entry.dial), targetDurationS: nil,
                                targetPaceSPerKm: PlanEngine.pace(.long, p5k: p5k),
                                rationale: entry.rationale)

        case let .runWalk(runMin, walkMin):
            let grammar = "Run/walk \(Int(runMin)):\(Int(walkMin))"
            return Prescription(name: entry.name, runType: .easy, intervals: grammar,
                                targetDistanceM: nil, targetDurationS: minutes(entry.dial) * 60,
                                targetPaceSPerKm: PlanEngine.pace(.easy, p5k: p5k),
                                rationale: entry.rationale)
        }
    }

    /// Rough total time for a built workout (s) — Σ paced distances + fixed durations. Duration
    /// steps count as-is; unpaced distance steps price at the given easy pace.
    static func estimatedDurationS(_ workout: StructuredWorkout, easyPaceSPerKm: Double) -> Double {
        workout.steps.reduce(0) { sum, step in
            switch step.target {
            case let .duration(s): return sum + s
            case let .distance(m): return sum + m / 1000 * (step.paceSPerKm ?? easyPaceSPerKm)
            }
        }
    }
}

extension WorkoutLibrary.Prescription {
    func fitting(plan: TrainingPlan, profile: UserProfile?, unit: DistanceUnit) -> Self {
        let preferences = profile?.planPreferences
        let limit = runType == .long ? preferences?.longRunLimitS : preferences?.regularRunLimitS
        let input = GeneratedSession(dayOffset: 0, discipline: .running, runType: runType,
            targetDistanceM: targetDistanceM, targetDurationS: targetDurationS,
            targetPaceSPerKm: targetPaceSPerKm, intervals: intervals, rationale: rationale)
        let fitted = RunPrescriptionBudget.constrain(input, p5k: plan.p5kSPerKm,
            raceDistanceM: profile?.raceDistanceM, goalPace: plan.goalRacePaceSPerKm, limitS: limit, unit: unit)
        var result = self
        result.runType = fitted.runType ?? runType; result.intervals = fitted.intervals
        result.targetDistanceM = fitted.targetDistanceM; result.targetDurationS = fitted.targetDurationS
        result.targetPaceSPerKm = fitted.targetPaceSPerKm ?? targetPaceSPerKm
        result.rationale = fitted.rationale ?? rationale
        if fitted.intervals != intervals || fitted.runType != runType {
            result.name = fitted.runType == .easy ? "Easy run" : name
            result.rationale = "Adjusted to fit your complete workout budget. " + result.rationale
        }
        return result
    }

    /// A `PlannedSession` carrying this prescription — the exact field shapes the plan generator
    /// writes, so preview, live guidance, adaptation, and scoring all read it identically. Not
    /// inserted anywhere; the caller owns persistence (or discards it — previews do).
    func makeSession(on date: Date, calendar: Calendar = .current) -> PlannedSession {
        let s = PlannedSession()
        s.date = calendar.startOfDay(for: date)
        s.discipline = .running
        s.runType = runType
        s.intervals = intervals
        s.targetDistanceM = targetDistanceM
        s.targetDurationS = targetDurationS
        s.targetPaceSPerKm = targetPaceSPerKm
        s.rationale = rationale
        s.status = .planned
        return s
    }
}
