import Foundation

/// The coach's curated running/fitness knowledge — the questions every runner asks, answered
/// deterministically and personalized with the athlete's own numbers wherever they exist (their
/// Daniels paces, their race, their plan). This is what lets the offline coach answer far beyond
/// keyword commands: fully on-device, testable, and consistent with every principle the engines
/// enforce (fueling not dieting, never a diagnosis, no-shame tone, rules compute).
///
/// Matching is first-hit against ordered topics (specific before general). The medical boundary is
/// checked first and always wins — symptoms and conditions get "see a professional", never advice.
enum CoachKnowledge {

    /// The interpolation inputs — every field optional; answers degrade gracefully without them.
    struct Facts: Sendable {
        var p5kSPerKm: Double? = nil
        var raceDistanceM: Double? = nil
        var weeksToRace: Int? = nil
        var daysPerWeek: Int = 0
        var distanceUnit: DistanceUnit = .auto
    }

    struct Topic: Sendable {
        let keywords: [String]
        let answer: @Sendable (Facts) -> String
    }

    /// The library answer for a message, or nil when no topic matches (the caller keeps its own
    /// fallback). Input is matched lowercased.
    static func answer(for message: String, facts: Facts = Facts()) -> String? {
        let q = message.lowercased()
        if medicalKeywords.contains(where: { q.contains($0) }) {
            return "That's beyond what a training coach should weigh in on, and I won't guess about your health. Please talk to a medical professional about it. If it's happening during exercise right now, stop and get checked before your next session. I'll be here to adjust the plan around whatever they say."
        }
        return topics.first { $0.keywords.contains(where: { q.contains($0) }) }?.answer(facts)
    }

    // MARK: - The medical boundary (never coached around)

    private static let medicalKeywords = [
        "chest pain", "chest tight", "heart condition", "palpitation", "dizzy", "dizziness",
        "faint", "passed out", "blood pressure", "medication", "pregnan", "diabet", "asthma",
        "numbness", "can't feel my", "cant feel my"
    ]

    // MARK: - Pace interpolation

    private static func paceLine(_ type: RunType, _ f: Facts, prefix: String = "For you right now that's about") -> String {
        guard let p5k = f.p5kSPerKm, p5k > 0 else { return "" }
        let pace = DanielsPaces.trainingPace(type, p5kSPerKm: p5k)
        return " \(prefix) \(Formatters.pace(secPerKm: pace, unit: f.distanceUnit))."
    }

    // MARK: - Topics (specific before general; first hit wins)

    static let topics: [Topic] = [

        // ── Workout types and pacing concepts ─────────────────────────────────────────────
        Topic(keywords: ["tempo", "threshold"]) { f in
            "A tempo run is comfortably hard: roughly the pace you could race for an hour, held steady. It teaches your body to clear lactate as fast as it makes it, which is what makes race pace feel sustainable."
            + paceLine(.tempo, f, prefix: "Your tempo pace right now is about")
        },
        Topic(keywords: ["what are intervals", "interval training", "interval session", "vo2", "speed work", "speedwork", "track workout", "repeats"]) { f in
            "Intervals are short hard repeats with recovery between them, run near your maximum aerobic power. The rest is the point: it lets you accumulate more time at high intensity than one continuous effort ever could."
            + paceLine(.intervals, f, prefix: "Your interval pace lives around")
        },
        Topic(keywords: ["zone 2", "zone two", "easy pace", "easy runs", "run so slow", "running slow", "conversational pace", "80/20", "run slower", "too slow"]) { f in
            "Easy running is where most of your engine gets built: it grows capillaries and mitochondria with almost no recovery cost, which is why the best runners in the world do most of their volume there. If you can't hold a conversation, it's not easy."
            + paceLine(.easy, f, prefix: "Your easy pace is about")
        },
        Topic(keywords: ["point of the long run", "why long run", "purpose of the long run", "long runs important", "what does the long run", "why do i have a long run"]) { f in
            "The long run teaches your body to burn fat efficiently, toughens tendons and joints, and builds the durability every race distance leans on. It should feel unhurried: time on feet matters more than pace."
            + paceLine(.long, f, prefix: "Yours should sit around")
        },
        Topic(keywords: ["fartlek"]) { _ in
            "Fartlek is Swedish for speed play: unstructured surges inside an easy run, by feel, off landmarks or minutes instead of a track. It builds the same engine as intervals with less mental load, and it's a great bridge into structured speed work."
        },
        Topic(keywords: ["strides"]) { _ in
            "Strides are 15 to 20 second relaxed accelerations up to about mile pace, with full recovery. They sharpen your form and leg speed without fatigue cost, which is why they hide at the end of easy days. Smooth beats fast: think tall posture and quick feet."
        },
        Topic(keywords: ["progression run"]) { _ in
            "A progression run starts easy and finishes fast, teaching you to run strong on tired legs. Start a notch slower than usual and squeeze down gradually, finishing the last stretch near tempo effort. It's race craft disguised as a normal run."
        },
        Topic(keywords: ["negative split", "positive split", "even split"]) { _ in
            "A negative split means running the second half faster than the first, and it's how most distance records are set. Banking time early almost always costs more than it saves. Aim even to slightly conservative early, then let the last third earn the result."
        },
        Topic(keywords: ["cadence", "steps per minute", "step rate"]) { _ in
            "Cadence is your steps per minute. There's no magic 180: most runners land somewhere between 160 and 185, and it naturally rises with speed. If yours is very low it can mean overstriding, so think shorter, quicker steps landing under your hips rather than forcing a number."
        },
        Topic(keywords: ["overstriding", "heel strike", "foot strike", "footstrike", "running form", "posture", "technique"]) { _ in
            "Good form is individual, but relaxed posture helps: run tall, lean slightly from the ankles, and avoid forcing a foot strike. Change one cue at a time and only when it solves a real problem; sudden overhauls can disrupt a stride that was working."
        },
        Topic(keywords: ["breathing", "out of breath", "winded", "breathe while"]) { _ in
            "If you're gasping on easy runs, the fix is pace, not lungs: slow down until you could speak in sentences. Belly breathing (letting your stomach expand) beats shallow chest breaths, and rhythmic patterns like three steps in, two out can settle things on harder efforts."
        },
        Topic(keywords: ["side stitch", "stitch", "side cramp", "cramp in my side"]) { _ in
            "Stitches usually come from starting too fast, eating too close to the run, or shallow breathing. Slow down, exhale hard as the foot opposite the stitch lands, and press gently on the spot. Prevention: leave 2 or more hours after a full meal and warm into the first kilometer gently."
        },

        // ── Training structure ────────────────────────────────────────────────────────────
        Topic(keywords: ["taper"]) { f in
            var out = "The taper trims volume while keeping a little intensity, so fitness stays sharp while fatigue drains away. You can't gain fitness in the final two weeks, but you can absolutely lose freshness by cramming. Feeling twitchy and restless during a taper is normal: that's the energy you'll spend on race day."
            if let w = f.weeksToRace, w <= 3 { out += " You're \(w == 0 ? "inside race week" : "\(w) week\(w == 1 ? "" : "s") out"), so trust the work that's already banked." }
            return out
        },
        Topic(keywords: ["base building", "base phase", "aerobic base", "base training"]) { _ in
            "Base building is weeks of mostly easy volume that everything else stands on. A bigger aerobic base means faster recovery between hard sessions, better fat burning, and more durable legs. It feels unglamorous, and it's the single highest-return phase in the plan."
        },
        Topic(keywords: ["periodization", "training phases", "training block", "build phase", "peak phase", "macrocycle"]) { _ in
            "Plans move through phases: base (mostly easy volume), build (quality sessions layered in), peak (the sharpest race-specific work), then taper. Each phase earns the next one. That's also why your plan changes character over the weeks instead of repeating one hard week forever."
        },
        Topic(keywords: ["rest day", "rest days", "day off", "days off", "take a break from running"]) { _ in
            "Rest days are where the training actually lands: stress plus recovery equals adaptation, and skipping the recovery half just accumulates fatigue. They're in the plan on purpose, they count toward your streak, and taking them seriously is a competitive advantage, not a weakness."
        },
        Topic(keywords: ["cross train", "cross-train", "crosstrain", "cycling instead", "bike instead", "swim instead", "elliptical"]) { _ in
            "Cross training (cycling, swimming, the elliptical) keeps your aerobic engine running with far less impact. It's a great swap when your legs need a break or when life blocks a run. It doesn't fully replace running's specific loading, so keep your key run sessions when you can."
        },
        Topic(keywords: ["twice a day", "two runs a day", "doubles", "run in the morning and"]) { _ in
            "Doubles make sense for high-mileage runners who can't fit the volume in single sessions, and mostly not before that. Splitting a run doesn't add much unless total weekly volume is already high. Most athletes get more from one quality session and proper sleep than from a second run."
        },
        Topic(keywords: ["should i lift", "strength training help", "lifting help", "weights help", "gym help", "strength work for run"]) { f in
            let days = f.daysPerWeek > 0 ? " Your plan already budgets for it around your \(f.daysPerWeek) training days." : ""
            return "Well-designed strength work can support running economy and force production. For runners that means progressive, well-recovered work—squats, hinges, calf raises, and trunk work—not exhausting circuits. Keep demanding lower-body work away from your hardest run when the schedule allows." + days
        },
        Topic(keywords: ["get faster", "run faster", "improve my 5k", "improve my 10k", "improve my time", "speed up my", "how do i improve"]) { f in
            var out = "Running improvement usually comes from consistent weeks, mostly easy work, and a small amount of targeted quality that fits your experience and event. Your plan builds those pieces gradually; no single workout carries the season."
            if let p5k = f.p5kSPerKm, p5k > 0 {
                out += " Your pace estimate changes only when comparable running evidence supports it, so one unusually good or bad day does not rewrite the plan."
            }
            return out
        },

        // ── Physiology and the numbers ────────────────────────────────────────────────────
        Topic(keywords: ["vdot", "daniels"]) { _ in
            "VDOT is Jack Daniels' fitness score: one number derived from a race performance that maps to all your training paces. It's how a 5K time can prescribe your easy, tempo, and interval paces. Your plan uses the same tables, calibrated from your own running."
        },
        Topic(keywords: ["acwr", "acute chronic", "load balance", "what is training load", "training load mean"]) { _ in
            TrainingLoadContext.methodExplanation
        },
        Topic(keywords: ["hrv", "heart rate variability"]) { _ in
            "HRV is the variation between heartbeats. It can add recovery context when compared with your own stable baseline, but it is noisy and can move with training, sleep, illness, alcohol, measurement timing, and life stress. I never use one reading as clearance or as a diagnosis."
        },
        Topic(keywords: ["resting heart rate", "resting hr", "rhr"]) { _ in
            "Resting heart rate can shift with fitness, fatigue, temperature, hydration, illness, medication, and measurement conditions. I compare it with your own recent baseline and other signals; one morning value does not automatically cancel or approve a session."
        },
        Topic(keywords: ["max heart rate", "maximum heart rate", "max hr", "220 minus"]) { _ in
            "Age formulas are rough population estimates and can miss an individual's max heart rate. Use a trustworthy value you already observed in an appropriate hard effort, or keep the estimate and treat the zones as provisional. You never need to perform an unsupervised maximal test just to use the plan."
        },
        Topic(keywords: ["heart rate drift", "hr drift", "cardiac drift", "heart rate keeps climbing", "hr keeps going up", "hr so high on easy"]) { _ in
            "Heart rate drifting upward at a steady pace is normal: heat, dehydration, and accumulating fatigue all push it up over a run. It's why later kilometers read higher for the same effort. If easy runs start high from the first kilometer, that's more often pace, heat, caffeine, or a rough night."
        },
        Topic(keywords: ["rpe", "perceived effort", "perceived exertion"]) { _ in
            "RPE is your own 1 to 10 read on how hard a session felt, and it's more useful than it looks: it catches things sensors miss, like stress and poor sleep. Easy should feel like 3 to 4, tempo around 6 to 7, intervals 8 to 9. When RPE and pace disagree, believe RPE."
        },
        Topic(keywords: ["runner's high", "runners high"]) { _ in
            "It's real: sustained aerobic exercise releases endocannabinoids that lift mood and blunt discomfort. It tends to show up on relaxed, medium-length runs rather than hard ones. If you've felt it, that's your brain paying you for consistency."
        },
        Topic(keywords: ["hit the wall", "bonk", "the wall at"]) { _ in
            "A late-race collapse can involve depleted carbohydrate stores, pacing, heat, hydration, muscle damage, or several factors together. Practiced fueling, an honest first half, and event-specific long runs can reduce the chance, but no tactic guarantees it."
        },

        // ── Environment and gear ──────────────────────────────────────────────────────────
        Topic(keywords: ["treadmill"]) { _ in
            "Treadmill runs count. Belt calibration, cooling, and the runner change how treadmill pace compares with outdoors, so there is no universal incline correction. Follow effort first, confirm the distance you trust, and log it manually so the session credits your plan."
        },
        Topic(keywords: ["uphill", "downhill", "hill repeats", "hilly", "run hills", "incline"]) { _ in
            "Hills are strength work in disguise. Going up: shorten your stride, pump your arms, and hold effort steady rather than pace (your pace should slow). Coming down: slight forward lean, quick light steps, and don't brake with your heels, since downhill braking is what shreds quads."
        },
        Topic(keywords: ["shoe", "sneaker", "footwear", "carbon plate"]) { _ in
            "Shoes are personal: prioritize comfort, fit, and how they feel late in a run over category labels. Lifespan varies with the runner, shoe, and surface, so replace a pair when cushioning, grip, or comfort meaningfully changes. Introduce carbon-plated shoes gradually before racing in them."
        },
        Topic(keywords: ["hot out", "in the heat", "humid", "summer running", "run in heat"]) { _ in
            "Heat and humidity often slow pace, but the size of the change is personal and condition-specific. Run by effort, choose a cooler time or route when possible, bring appropriate fluids for the session, and build exposure gradually. Stop and seek help for concerning heat-illness symptoms."
        },
        Topic(keywords: ["cold out", "winter run", "freezing", "in the snow", "run in the cold"]) { _ in
            "Cold running is mostly a dressing problem: dress for 10 degrees warmer than the actual temperature, because you'll heat up fast. Layers you can shed, something for hands and ears, and a longer warmup before any quality work. Traction beats pace on ice, so shorten your stride."
        },
        Topic(keywords: ["in the rain", "wet weather", "raining"]) { _ in
            "Rain is fine to train in, and racing in it is a skill worth having. A brimmed cap keeps it out of your eyes, anti-chafe balm matters double, and wet shoes go faster stuffed with newspaper than by a radiator. The run always feels better than the first wet minute suggests."
        },
        Topic(keywords: ["music", "podcast", "headphones", "listen to while"]) { _ in
            "Whatever gets you out the door. Music measurably lowers perceived effort on easy runs; for hard sessions and race rehearsal it's worth practicing without, since most races restrict headphones. Keep the volume low enough to hear what's around you."
        },

        // ── Fueling and hydration (fueling, never dieting) ────────────────────────────────
        Topic(keywords: ["carb load", "carb-load", "carbo load", "carbo-load", "pasta dinner"]) { _ in
            "Carb loading only matters for efforts beyond about 90 minutes. It's 36 to 48 hours of carb-focused meals at normal portions, not one giant pasta night. Nothing new on race weekend: familiar foods, slightly bigger carb share, done."
        },
        Topic(keywords: ["electrolyte", "salt tab", "sodium", "cramping"]) { _ in
            "Fluid and sodium needs vary with duration, weather, sweat rate, acclimation, and the athlete. Practice a fueling-and-fluid plan during long runs instead of guessing on race day. Cramps can have several contributors, so recurring or severe episodes deserve individual review rather than an automatic salt prescription."
        },
        Topic(keywords: ["caffeine", "coffee before"]) { _ in
            "Caffeine genuinely works: roughly 2 to 3 mg per kg about 45 to 60 minutes before a hard session or race improves endurance performance. A normal coffee covers most people. Practice it in training first, and skip late-day doses since sleep is the bigger lever."
        },
        Topic(keywords: ["lose weight", "weight loss", "burn fat", "calories", "diet"]) { _ in
            "I coach fueling, not dieting, so I won't set a weight-loss calorie target or promise a weight outcome. Momentum can build a consistent running routine and help you eat enough for the work. For an individual body-composition goal—especially alongside high training load—a registered dietitian is the right professional."
        },

        // ── Recovery ──────────────────────────────────────────────────────────────────────
        Topic(keywords: ["stretch", "foam roll", "mobility", "flexib", "yoga"]) { _ in
            "A short dynamic warm-up can help you feel ready to move; static stretching or foam rolling afterward is optional if it feels useful. None is an injury guarantee. Choose the small routine you will repeat without taking recovery away from the training that matters."
        },
        Topic(keywords: ["doms", "soreness normal", "muscle soreness", "sore after", "legs are sore from"]) { _ in
            "Next-day soreness after new or hard work is normal adaptation, peaks around 48 hours, and easy movement helps it clear. The line to respect: soreness is dull, both-sided, and fades as you warm up. Pain that's sharp, one-sided, or gets worse while running is different, and if that's what you've got, tell me where and I'll adjust the plan."
        },
        Topic(keywords: ["how much sleep", "sleep do i need", "sleep important", "sleep for recovery", "sleep and running"]) { _ in
            "Sleep is where much of the rebuilding happens. Many adults land around 7 to 9 hours, but your own trend and how you function matter more than chasing one perfect number. Repeated short nights can show up as flat legs, elevated resting HR, and poor session quality; recovery can be more valuable than squeezing in extra easy volume."
        },
        Topic(keywords: ["overtraining syndrome", "burned out", "burnout", "no motivation to run"]) { _ in
            "Persistent flatness, sleep disruption, unusual fatigue, or a major motivation change deserves attention, but those signs are not specific enough for the app to diagnose overtraining. Ease the immediate pressure, review the full context, and involve a qualified clinician when symptoms persist or concern you."
        },
        Topic(keywords: ["shin splint"]) { _ in
            "Shin pain has several possible causes, and I can't diagnose it from chat. Tell me where it hurts and how it behaves so I can reduce aggravating training; focal, worsening, or persistent pain should be assessed by a qualified professional rather than trained through."
        },
        Topic(keywords: ["prevent injur", "avoid injur", "injury prevention", "stay healthy", "not get hurt"]) { _ in
            "No plan can promise injury prevention. Momentum uses conservative progression, recovery spacing, runner-strength support, and early symptom feedback to avoid unnecessary training pressure. Tell me early when something changes; persistent, worsening, or concerning pain belongs with a qualified professional."
        },

        // ── Race craft ────────────────────────────────────────────────────────────────────
        Topic(keywords: ["race morning", "race day tips", "morning of the race", "before my race what", "race day checklist", "line up", "corral"]) { _ in
            "Race morning rules: nothing new (breakfast, kit, and shoes all rehearsed), arrive with time to spare, easy jog plus a few strides to warm up, and start a notch slower than feels right, because adrenaline lies. Lay everything out the night before so the morning is just execution."
        },
        Topic(keywords: ["dnf", "drop out of the race", "quit the race"]) { _ in
            "A DNF for injury or illness is a smart decision, not a failure: one race is never worth a season. A DNF because the day went sideways happens to every distance runner eventually. Either way it's data, we learn from it, and the fitness you built doesn't vanish."
        }
    ]
}
