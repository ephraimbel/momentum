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
    struct Facts {
        var p5kSPerKm: Double? = nil
        var raceDistanceM: Double? = nil
        var weeksToRace: Int? = nil
        var daysPerWeek: Int = 0
        var distanceUnit: DistanceUnit = .auto
    }

    struct Topic {
        let keywords: [String]
        let answer: (Facts) -> String
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
            "Good form is mostly posture: run tall, lean slightly from the ankles, and let your feet land under your hips instead of reaching out in front. Where your foot strikes matters far less than where it lands relative to your body. Change form gradually if at all, because sudden overhauls are an injury risk."
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
            return "Yes. Two short strength sessions a week measurably cut injury risk and improve running economy. For runners that means heavy and simple (squats, hinges, calf raises, core), not exhausting circuits. Keep it away from your hardest run days when you can." + days
        },
        Topic(keywords: ["get faster", "run faster", "improve my 5k", "improve my 10k", "improve my time", "speed up my", "how do i improve"]) { f in
            var out = "Three things make runners faster, in order: consistency over months, enough easy volume, and one or two quality sessions a week. That's exactly how your plan is built. The unglamorous truth is that missing zero weeks beats any magic workout."
            if let p5k = f.p5kSPerKm, p5k > 0 {
                out += " Your calibrated fitness updates every time you show real speed, so the plan's paces climb with you."
            }
            return out
        },

        // ── Physiology and the numbers ────────────────────────────────────────────────────
        Topic(keywords: ["vdot", "daniels"]) { _ in
            "VDOT is Jack Daniels' fitness score: one number derived from a race performance that maps to all your training paces. It's how a 5K time can prescribe your easy, tempo, and interval paces. Your plan uses the same tables, calibrated from your own running."
        },
        Topic(keywords: ["acwr", "acute chronic", "load balance", "what is training load", "training load mean"]) { _ in
            "Your load balance (ACWR) compares the last 7 days of training against your 28-day norm. The sweet spot is roughly 0.8 to 1.3: below it you're detraining, above about 1.5 injury risk climbs fast. It's the number I watch before saying yes to more volume."
        },
        Topic(keywords: ["hrv", "heart rate variability"]) { _ in
            "HRV is the tiny variation between heartbeats, and it's one of the best windows into recovery: higher than your norm generally means recovered, suppressed means stress (training, sleep, illness, life). It only means something against your own baseline, which is exactly how I read it."
        },
        Topic(keywords: ["resting heart rate", "resting hr", "rhr"]) { _ in
            "Resting heart rate falls as you get fitter and rises when you're under-recovered or getting sick. A morning value 4 or more beats above your norm is worth respecting with an easier day. Trend beats any single reading."
        },
        Topic(keywords: ["max heart rate", "maximum heart rate", "max hr", "220 minus"]) { _ in
            "The 220-minus-age formula misses badly for lots of people, sometimes by 15 or more beats. The best field estimate is the highest value you see at the end of a hard uphill finish or a 5K race. Set it in your profile and your zones recalculate instantly."
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
            "The wall is glycogen running out, usually past 90 minutes of hard running. The fix is fueling before and during (carbs early and often), pacing honestly in the first half, and training your gut on long runs. Marathoners who fuel properly mostly don't meet it."
        },

        // ── Environment and gear ──────────────────────────────────────────────────────────
        Topic(keywords: ["treadmill"]) { _ in
            "Treadmills count fully: same engine, same adaptations. A 1% incline roughly matches outdoor effort at most paces. GPS obviously can't track it, so log those runs manually and they'll credit your plan the same as any road run."
        },
        Topic(keywords: ["uphill", "downhill", "hill repeats", "hilly", "run hills", "incline"]) { _ in
            "Hills are strength work in disguise. Going up: shorten your stride, pump your arms, and hold effort steady rather than pace (your pace should slow). Coming down: slight forward lean, quick light steps, and don't brake with your heels, since downhill braking is what shreds quads."
        },
        Topic(keywords: ["shoe", "sneaker", "footwear", "carbon plate"]) { _ in
            "Shoes are personal, but the rules of thumb hold: comfort predicts injury risk better than any category label, most shoes are done between 500 and 800 km, and rotating two pairs measurably lowers injury rates. Save carbon plates for races and workouts, and do your easy volume in something with more life in it."
        },
        Topic(keywords: ["hot out", "in the heat", "humid", "summer running", "run in heat"]) { _ in
            "Heat is honest: your pace slows 3 to 5% and that's physiology, not weakness. Run by effort instead of pace, go early or late, and drink to thirst. Full heat adaptation takes about two weeks of consistent exposure, and the fitness you build in it shows up when it cools."
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
            "Electrolytes matter on hot days and efforts past about 90 minutes, especially if you finish crusted in salt. Drinking to thirst plus some sodium on long hot sessions covers most runners. Cramps are usually more about pacing and conditioning than salt, though: the fitter you are at the pace, the less you cramp."
        },
        Topic(keywords: ["caffeine", "coffee before"]) { _ in
            "Caffeine genuinely works: roughly 2 to 3 mg per kg about 45 to 60 minutes before a hard session or race improves endurance performance. A normal coffee covers most people. Practice it in training first, and skip late-day doses since sleep is the bigger lever."
        },
        Topic(keywords: ["lose weight", "weight loss", "burn fat", "calories", "diet"]) { _ in
            "I coach fueling, not dieting, so I won't hand out calorie targets. What I can tell you: underfueling training is the fastest way to get slower, sick, or hurt, and performance improves body composition far more sustainably than restriction does. Fuel the work, sleep well, and let consistency do the quiet part. For anything beyond that, a registered dietitian is the right pro."
        },

        // ── Recovery ──────────────────────────────────────────────────────────────────────
        Topic(keywords: ["stretch", "foam roll", "mobility", "flexib", "yoga"]) { _ in
            "The evidence is modest but friendly: dynamic movement before running, and save long static stretches or the foam roller for after, if you enjoy them. Neither prevents injury on its own. If you have ten spare minutes, easy strength work returns more than stretching."
        },
        Topic(keywords: ["doms", "soreness normal", "muscle soreness", "sore after", "legs are sore from"]) { _ in
            "Next-day soreness after new or hard work is normal adaptation, peaks around 48 hours, and easy movement helps it clear. The line to respect: soreness is dull, both-sided, and fades as you warm up. Pain that's sharp, one-sided, or gets worse while running is different, and if that's what you've got, tell me where and I'll adjust the plan."
        },
        Topic(keywords: ["how much sleep", "sleep do i need", "sleep important", "sleep for recovery", "sleep and running"]) { _ in
            "Sleep is the best legal performance enhancer there is: it's when the actual rebuilding happens. Athletes in training generally need 7 to 9 hours, and chronic shortage shows up as flat legs, elevated resting HR, and higher injury risk. If you must choose, an extra hour of sleep beats an extra easy run."
        },
        Topic(keywords: ["overtraining syndrome", "burned out", "burnout", "no motivation to run"]) { _ in
            "Persistent flatness, disturbed sleep, elevated resting HR, and vanishing motivation are the classic overreaching signs, and the cure is unheroic: several genuinely easy days and honest sleep. Motivation dips are also just normal, so don't diagnose yourself off one bad week. I watch your load and recovery signals for exactly this, and I'll pull the plan back before you dig a hole."
        },
        Topic(keywords: ["shin splint"]) { _ in
            "Shin splints usually trace to ramping volume too fast, worn shoes, or lots of hard surface. Prevention is gradual load (which your plan enforces), fresh shoes, and calf strength. If your shins are actively hurting, tell me it hurts and where, and I'll take you through the injury flow and train around it."
        },
        Topic(keywords: ["prevent injur", "avoid injur", "injury prevention", "stay healthy", "not get hurt"]) { _ in
            "Most running injuries are load errors: too much, too soon, too fast. Your protection is already built in here: gradual ramps, a hard weekly-change budget, recovery watching, and strength work. Your end of the deal is sleeping enough, respecting easy days, and telling me early when something feels off. Early honesty costs a session; late honesty costs a month."
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
