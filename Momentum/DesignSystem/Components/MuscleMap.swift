import SwiftUI

/// A human-body muscle map (PRD §4.4) — the strength-context brand visual (see also `BrandMark`). Anatomically
/// detailed front + back figures whose muscles glow with the **earned iridescent** accent, intensity
/// scaled by how much each muscle was worked. 100% Apple-native: real anatomical SVG paths (see
/// `MuscleBodyData`, MIT) are parsed into SwiftUI `Path`s at runtime — no map/UI SDKs, no bitmap art.
///
/// Drive it with a `[MuscleGroup: Double]` (e.g. `MuscleActivation` / `StrengthMath`): unworked
/// muscles read as a faint anatomy chart, worked muscles light up, the most-worked burns fullest and
/// the rest scale relative to it. Honors Reduce Motion (iridescence holds static via `IridescentView`).
///
/// Two visual languages, chosen by `grading` (see `MuscleMapGrading.tone`): post-session surfaces
/// keep the celebratory oil-slick over everything worked, while the Trends figures speak the
/// muscle-load wheel's growth language — brand lavender that DEEPENS with training, the earned
/// burn only at the top of the scale — so the region leading the wheel is the region carrying the
/// most colour on the body, at the same strength, every time.
struct MuscleMapView: View {
    let activation: [MuscleGroup: Double]
    /// Which figures to show, left→right. Default front + back (the iconic anatomy-chart look).
    var sides: [BodySide] = [.front, .back]
    /// How activation becomes fill intensity — `.session` (default, the rich post-workout burn),
    /// `.weeklyVolume` (the Athlete Panel's absolute training portrait) or `.regionShare` (the
    /// muscle-load wheel's share-of-the-leader). See `MuscleMapGrading`.
    var grading: MuscleMapGrading = .session
    /// The body figure to render — `.female` renders the true female anatomical dataset. `nil`
    /// (the default) uses the athlete's own figure (`AthleteFigure.sex`), so most call sites need
    /// not pass anything; explicit callers (onboarding, the athlete panel) still override.
    var sex: BodySex? = nil
    /// Force the iridescence to hold static (no animated `MeshGradient`). Set when many maps render at
    /// once — e.g. the profile grid — so the tiles stay at 60fps. Independent of Reduce Motion.
    var forceStatic: Bool = false

    private var resolvedSex: BodySex { sex ?? AthleteFigure.sex }

    /// `.fullBody` credit floods every muscle (cardio/HIIT/"other"); fold it into the real regions.
    private var resolved: [MuscleGroup: Double] {
        var m = activation
        if let fb = m.removeValue(forKey: .fullBody), fb > 0 {
            for muscle in MuscleGroup.allCases where muscle != .fullBody {
                m[muscle] = max(m[muscle] ?? 0, fb)
            }
        }
        return m
    }

    private var maxVal: Double { resolved.values.max() ?? 0 }

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            ForEach(sides) { side in
                BodyFigure(side: side, activation: resolved, maxVal: maxVal, sex: resolvedSex,
                           forceStatic: forceStatic, grading: grading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let worked = resolved.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !worked.isEmpty else { return "Muscle map — nothing worked yet." }
        return "Muscles worked: " + worked.prefix(5).map { $0.key.displayName.lowercased() }.joined(separator: ", ") + "."
    }
}

/// The ONE lighting law for trained tissue (owner call 2026-08-29: "the body and the muscle map
/// have to correlate perfectly"). The muscle-load wheel's ring segments and the body figure's
/// muscles both run their value through these two functions, so a region reading strong on the
/// wheel reads exactly as strong on the figure — and a muscle that has been trained more over the
/// window is visibly deeper in brand lavender than one that hasn't.
///
/// Two stops, in order: **lavender deepens** with the work (the whole readable range), and the
/// **iridescent burn** is reserved for the very top of the scale — the region leading the wheel,
/// or a muscle carrying full weekly volume. Iridescence stays earned; lavender carries the growth.
enum MuscleLight {
    /// The faintest a lit thing is allowed to be: below this a barely-trained region stops
    /// reading as trained at all. ONE floor for every surface — a wheel ring, a by-region bar and
    /// a muscle at the same share must come out at the same alpha, or the screen shows one number
    /// in three depths and the athlete has to decide which to believe.
    static let floor: Double = 0.08

    /// The law itself: lavender alpha rises LINEARLY with strength `t` (0…1), from the floor to
    /// full saturation. Linear on purpose — alpha is proportional to the work, so twice the
    /// training really is twice the colour, wherever it is drawn.
    static func lavender(_ t: Double) -> Double { floor + (1 - floor) * clamped(t) }

    /// Where the earned iridescence begins. Below it a muscle is lavender and nothing else, so a
    /// second-place region can never wear the burn that marks the top of the athlete's training.
    static let burnThreshold: Double = 0.97

    /// How much oil-slick shows through at strength `t` — 0 below the threshold, full at 1.
    static func burn(_ t: Double) -> Double {
        max(0, (clamped(t) - burnThreshold) / (1 - burnThreshold))
    }

    static func clamped(_ t: Double) -> Double { min(1, max(0, t)) }

    /// The fill for one body region at `share` of the leading region — the single style the
    /// muscle-load wheel's rings and its by-region bars both draw from, and the flat-fill twin of
    /// what `BodyFigure` paints on the anatomy. The leader wears the earned aurora at brand depth;
    /// everyone else is brand lavender at exactly the alpha their share earns.
    static func regionStyle(share: Double, isLeader: Bool) -> AnyShapeStyle {
        guard isLeader else { return AnyShapeStyle(Theme.purple.opacity(lavender(share))) }
        return AnyShapeStyle(AngularGradient(colors: Theme.iridescentDeep + [Theme.iridescentDeep[0]],
                                             center: .center))
    }
}

/// How raw activation becomes fill intensity — three honest scales for three contexts.
enum MuscleMapGrading: Equatable {
    /// Post-session surfaces (summary, tiles, feed, live): what you just worked burns richly —
    /// 0.62…1.0 relative to the session's top muscle, the celebratory "covered body" look.
    case session
    /// The training portrait (Athlete Panel): values are **weekly working-set-equivalents** and the
    /// scale is ABSOLUTE — a lightly-touched muscle is a faint tint and only consistent volume
    /// (~10 sets/week, the classic hypertrophy bar) burns full. The figure starts blank, brightens
    /// as training accumulates, and every window (1M/3M/6M) grades by the same yardstick, so the
    /// muscles you actually train more visibly carry more light.
    case weeklyVolume
    /// The muscle-load wheel's own scale: the value IS the region's share of the leading region
    /// (0…1, `StrengthTrends.bodyShares`), graded exactly the way the wheel grades its rings. The
    /// figure under the wheel is then the wheel, drawn on a body — same leader, same falloff.
    case regionShare

    /// Weekly set-equivalents at which a muscle reaches full iridescence.
    static let fullBurnWeeklySets: Double = 10

    /// How lit tissue is COLOURED. `.burn` is the celebratory post-session oil-slick over
    /// everything worked; `.growth` is the progress language shared with the muscle-load wheel —
    /// lavender deepening with training, iridescence only at the top of the scale.
    enum Tone: Equatable { case burn, growth }

    var tone: Tone { self == .session ? .burn : .growth }

    /// Fill alpha for one muscle. `maxVal` is the map's top value — `.session` normalizes to it;
    /// `.weeklyVolume` deliberately ignores it (one easy week must not read as a fully-lit body).
    func intensity(_ value: Double, maxVal: Double) -> Double {
        guard value > 0 else { return 0 }
        // Contrast rule (owner call 2026-08-28): the difference must be VISIBLE on the body. The
        // old ramps compressed the range (session floor 0.62; a muscle at a third of the leader
        // still rendered ~60%), so a legs-heavy month read as a fully lit body. Both scales now
        // open up: the leader burns full, a muscle at half the leader is clearly dimmer, a touch
        // is a faint tint.
        switch self {
        case .session:
            guard maxVal > 0 else { return 0 }
            // ~0.30 at a tenth of the top muscle, 0.5 at half, 1.0 at the top.
            return 0.28 + 0.72 * pow(min(1, value / maxVal), 1.4)
        case .weeklyVolume:
            // LINEAR in the work, like `.regionShare` and like the wheel's rings (2026-08-29): the
            // Trends page draws this athlete twice, so the body at the top and the muscle-load
            // wheel below it have to turn "how much" into colour by the same rule or the same
            // training reads at two different depths on one page. The old `^1.5` also squashed the
            // bottom of the scale, where most athletes actually live — 1 set/wk and 3 sets/wk came
            // out nearly the same tint. ~1 set/wk = 0.19, 3 = 0.37, 5 = 0.55, 10+ = 1.0.
            return 0.10 + 0.90 * min(1, value / Self.fullBurnWeeklySets)
        case .regionShare:
            // Already a share of the leader — the wheel's number, used as the wheel uses it.
            return MuscleLight.clamped(value)
        }
    }
}

enum BodySide: String, Identifiable, CaseIterable {
    case front, back
    var id: String { rawValue }
    /// The other face. The Athlete Panel's figure turns between the two.
    var flipped: BodySide { self == .front ? .back : .front }
    /// Athlete-facing name, for captions and VoiceOver.
    var displayName: String { self == .front ? "Front" : "Back" }
}

/// Which body figure to render. `.neutral` is the (male) source anatomy; `.female` is the true
/// female anatomical dataset. Both are real SVG datasets from the same MIT source.
enum BodySex: Equatable { case neutral, female
    /// Map a stored profile sex (BiologicalSex raw) to a figure — only `female` changes the shape.
    init(profileSex: String?) { self = (profileSex == "female") ? .female : .neutral }
}

/// The athlete's OWN body figure — resolved once from their profile sex at the app root
/// (`AthleteFigure.sex = …`) and read as the DEFAULT by every `MuscleMapView`/`AnatomyGlowView`
/// that doesn't pass an explicit `sex`. So a female athlete sees her figure on every surface —
/// live lifting, summary, tiles, Today — with no per-call plumbing.
///
/// A plain `@MainActor` static rather than an environment value ON PURPOSE: the body renders inside
/// `fullScreenCover`s (the live workout, its summary, the immersive pager), and covers do NOT inherit
/// custom environment values across the presentation boundary (verified — the live-lift figure came
/// out male for a female athlete under the env approach). A global static is immune to that. Views
/// re-read it on every render, so changing sex in Profile → Edit updates them on the next pass.
/// Explicit callers (onboarding's live selection, the athlete panel) still override it.
@MainActor enum AthleteFigure { static var sex: BodySex = .neutral }

// MARK: - One figure

private struct BodyFigure: View {
    let side: BodySide
    let activation: [MuscleGroup: Double]
    let maxVal: Double
    var sex: BodySex = .neutral
    var forceStatic: Bool = false
    var grading: MuscleMapGrading = .session

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parts: [BodyAnatomy.Part] {
        switch (side, sex) {
        case (.front, .female): BodyAnatomy.femaleFront
        case (.back, .female):  BodyAnatomy.femaleBack
        case (.front, _):       BodyAnatomy.front
        case (.back, _):        BodyAnatomy.back
        }
    }
    private var outline: Path {
        switch (side, sex) {
        case (.front, .female): BodyAnatomy.femaleFrontOutline
        case (.back, .female):  BodyAnatomy.femaleBackOutline
        case (.front, _):       BodyAnatomy.frontOutline
        case (.back, _):        BodyAnatomy.backOutline
        }
    }
    /// The source viewBox for THIS figure — male and female use different coordinate spaces
    /// (the female art is taller and offset), so every scale/translate reads from here.
    private var box: BodyAnatomy.ViewBox { BodyAnatomy.viewBox(side, sex) }

    var body: some View {
        GeometryReader { geo in
            let lw = max(0.8, geo.size.width * 0.006)
            ZStack {
                // Unworked baseline — a quiet anatomy chart so the figure always reads.
                ForEach(parts.indices, id: \.self) { i in
                    shape(parts[i].path).fill(Theme.inkTertiary.opacity(0.11))
                }

                // Trained tissue, in the growth language (Trends' figures): brand lavender that
                // DEEPENS with the work — the muscle-load wheel's own ramp — so the part of the
                // body carrying more training is visibly more purple than the part carrying less.
                // `.session` skips this: what you just worked keeps the celebratory oil-slick.
                if grading.tone == .growth {
                    ForEach(parts.indices, id: \.self) { i in
                        let t = intensity(parts[i].muscle)
                        if t > 0 {
                            shape(parts[i].path).fill(Theme.purple.opacity(MuscleLight.lavender(t)))
                        }
                    }
                }

                // The earned oil-slick, revealed through the mask: every worked muscle under
                // `.session`, and under `.growth` only the top of the scale — the region leading
                // the wheel, a muscle at full weekly volume. (Mask alpha = per-muscle burn.)
                //
                // The growth figures burn in `Theme.iridescentDeep` — the same aurora at brand
                // depth. The stock pastel stops are lighter than a fully-lit lavender, so painting
                // the top of the scale in them made it the LIGHTEST thing on the body: the Athlete
                // Panel's own rail read "Shoulders — most worked" while the deltoids rendered as
                // the palest muscle on the figure. More training must never look like less.
                IridescentView(intensity: 1.0, isStatic: reduceMotion || forceStatic,
                               palette: grading.tone == .burn ? nil : Theme.iridescentDeep)
                    .mask(maskLayer(burn))

                // A soft top-lit sheen over the lit muscles — a subtle gloss so a covered body reads
                // glassy and premium, not flat. Static (no per-frame blur) so it's free on animation.
                //
                // `.session` ONLY. It is a vertical gradient (0.32 white at the crown, clear at the
                // feet), so under `.growth` it washed out whatever sat high on the figure: the
                // deltoids rendered palest while the panel's own rail read "Shoulders — most
                // worked". On a reading surface, where a muscle SITS must never outrank how much
                // it has been trained, so the growth figures wear no sheen at all.
                if grading.tone == .burn {
                    LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .blendMode(.softLight)
                        .mask(maskLayer(intensity))
                }

                // Worked muscles get a defining edge so the glow reads clearly against white.
                ForEach(parts.indices, id: \.self) { i in
                    let intensity = intensity(parts[i].muscle)
                    if intensity > 0 {
                        shape(parts[i].path).stroke(Theme.ink.opacity(0.16 + 0.24 * intensity), lineWidth: lw)
                    }
                }

                // Muscle separation lines + the body outline, both in ink.
                ForEach(parts.indices, id: \.self) { i in
                    shape(parts[i].path).stroke(Theme.ink.opacity(0.10), lineWidth: lw * 0.55)
                }
                shape(outline).stroke(Theme.ink.opacity(0.62),
                                      style: StrokeStyle(lineWidth: lw * 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func shape(_ path: Path) -> ScaledBodyShape { ScaledBodyShape(source: path, box: box) }

    /// A mask over the anatomy, each part filled at `alpha(muscle)`. Shared shape-building for the
    /// iridescent burn and the gloss sheen so both reveal through exactly the same shapes.
    private func maskLayer(_ alpha: @escaping (MuscleGroup?) -> Double) -> some View {
        ZStack {
            ForEach(parts.indices, id: \.self) { i in
                let a = alpha(parts[i].muscle)
                if a > 0 { shape(parts[i].path).fill(.white.opacity(a)) }
            }
        }
    }

    /// Unworked → 0; worked → the grading's ramp (see `MuscleMapGrading`).
    private func intensity(_ muscle: MuscleGroup?) -> Double {
        guard let muscle, let v = activation[muscle] else { return 0 }
        return grading.intensity(v, maxVal: maxVal)
    }

    /// How much iridescence this muscle has earned: everything worked under `.session` (the
    /// celebratory look, unchanged), only the top of the scale under `.growth`.
    private func burn(_ muscle: MuscleGroup?) -> Double {
        let t = intensity(muscle)
        return grading.tone == .burn ? t : MuscleLight.burn(t)
    }
}

/// Maps a parsed body `Path` (in source viewBox coords) onto the view, preserving aspect. Each
/// figure carries its own `ViewBox` (back paths and the female art live at their own min-x/min-y),
/// so the transform normalizes from that box into the render frame.
private struct ScaledBodyShape: Shape {
    let source: Path
    let box: BodyAnatomy.ViewBox
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / box.width
        let t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                  tx: rect.minX - box.minX * scale,
                                  ty: rect.minY - box.minY * scale)
        return source.applying(t)
    }
}

// MARK: - Parsed anatomy (slug → muscle, SVG path → SwiftUI Path), built once and cached

enum BodyAnatomy {
    /// A figure's source coordinate space. Male and female use DIFFERENT boxes (the female art is
    /// taller and offset), so scaling/positioning must read the right one per (side, sex).
    struct ViewBox: Equatable { let minX: CGFloat; let minY: CGFloat; let width: CGFloat; let height: CGFloat }

    /// The source viewBox for a figure — from each dataset's own SVG `viewBox`.
    /// Male front `0 0 724 1448`, back `724 0 724 1448`; female front `-50 -40 734 1538`,
    /// back `756 0 774 1448` (react-native-body-highlighter).
    static func viewBox(_ side: BodySide, _ sex: BodySex) -> ViewBox {
        switch (side, sex) {
        case (.front, .female): ViewBox(minX: -50, minY: -40, width: 734, height: 1538)
        case (.back, .female):  ViewBox(minX: 756, minY: 0, width: 774, height: 1448)
        case (.front, _):       ViewBox(minX: 0, minY: 0, width: 724, height: 1448)
        case (.back, _):        ViewBox(minX: 724, minY: 0, width: 724, height: 1448)
        }
    }

    struct Part { let muscle: MuscleGroup?; let path: Path }

    static let front: [Part] = build(MuscleBodyData.front, map: frontMuscle)
    // Back `head` is a wide hairline shape (the source strokes it as a thin line); as a fill it
    // smears grey outside the cranium, which `hair` + the outline already render cleanly. Drop it.
    static let back: [Part] = build(MuscleBodyData.back, map: backMuscle, skip: ["head"])
    static let frontOutline: Path = SVGPath.parse(MuscleBodyData.frontOutline)
    static let backOutline: Path = SVGPath.parse(MuscleBodyData.backOutline)

    // Female figures: the TRUE female anatomical dataset (react-native-body-highlighter, same MIT
    // source + identical slugs as the male set — so `frontMuscle`/`backMuscle` map it unchanged).
    // Data lives in `MuscleBodyDataFemale.swift`; each renders in its own `viewBox` above.
    static let femaleFront: [Part] = build(MuscleBodyData.femaleFront, map: frontMuscle)
    static let femaleBack: [Part] = build(MuscleBodyData.femaleBack, map: backMuscle)
    static let femaleFrontOutline: Path = SVGPath.parse(MuscleBodyData.femaleFrontOutline)
    static let femaleBackOutline: Path = SVGPath.parse(MuscleBodyData.femaleBackOutline)

    /// Touch every parsed static so the ~131 KB of SVG path parsing happens once, off the main
    /// thread, at launch — instead of inside the first frame that mounts a body figure (the first
    /// card of Progress ▸ Trends). `static let` initialization is thread-safe, so warming from a
    /// background task and a later main-thread read can race harmlessly.
    static func warm() {
        _ = (front, back, frontOutline, backOutline,
             femaleFront, femaleBack, femaleFrontOutline, femaleBackOutline)
    }

    private static func build(_ data: [(slug: String, paths: [String])],
                              map: (String) -> MuscleGroup?, skip: Set<String> = []) -> [Part] {
        data.compactMap { entry in
            guard !skip.contains(entry.slug) else { return nil }
            var path = Path()
            for d in entry.paths { path.addPath(SVGPath.parse(d)) }
            return Part(muscle: map(entry.slug), path: path)
        }
    }

    /// Front view: which slug highlights as which `MuscleGroup` (nil = structural, faint only).
    private static func frontMuscle(_ slug: String) -> MuscleGroup? {
        switch slug {
        case "chest": .chest
        case "abs", "obliques": .core
        case "biceps": .biceps
        case "triceps": .triceps
        case "deltoids": .shoulders
        case "trapezius": .back            // traps are a back muscle; they crest onto the front view
        case "quadriceps": .quads
        case "tibialis", "calves": .calves // front lower-leg reads as "calves" to users
        case "forearm": .forearms
        default: nil                       // neck, adductors, knees, hands, ankles, feet, head
        }
    }

    private static func backMuscle(_ slug: String) -> MuscleGroup? {
        switch slug {
        case "trapezius", "upper-back", "lower-back": .back
        case "deltoids": .shoulders
        case "triceps": .triceps
        case "forearm": .forearms
        case "gluteal": .glutes
        case "hamstring": .hamstrings
        case "calves": .calves
        default: nil                       // neck, adductors, ankles, feet, hands, head
        }
    }
}

// MARK: - Minimal SVG path parser (`d` attribute → SwiftUI Path)

/// Parses the subset of SVG path syntax used by the anatomy data: M/L/H/V/C/S/Q/T/Z (absolute &
/// relative). Elliptical arcs (A/a) appear only as sub-pixel rounding on fingers/toes, so they're
/// approximated by a line to the endpoint — visually identical at on-screen scale.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        var i = 0
        var cmd: Character = " "
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var prev: Character = " "

        func skipSep() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                    || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }
        func num() -> CGFloat {
            skipSep()
            let s = i
            var dot = false, exp = false, digit = false
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { digit = true; i += 1 }
                else if c == "." { if dot { break }; dot = true; i += 1 }
                else if (c == "e" || c == "E"), !exp, digit {
                    exp = true; i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else { break }
            }
            return CGFloat(Double(String(chars[s..<i])) ?? 0)
        }
        func reflect(_ p: CGPoint?, about c: CGPoint) -> CGPoint {
            guard let p else { return c }
            return CGPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)
        }

        while true {
            skipSep()
            guard i < chars.count else { break }
            if chars[i].isLetter {
                cmd = chars[i]; i += 1
            } else if cmd == "M" { cmd = "L" } else if cmd == "m" { cmd = "l" }

            let rel = cmd.isLowercase
            switch Character(cmd.uppercased()) {
            case "M":
                var p = CGPoint(x: num(), y: num())
                if rel { p = CGPoint(x: cur.x + p.x, y: cur.y + p.y) }
                path.move(to: p); cur = p; start = p
            case "L":
                var p = CGPoint(x: num(), y: num())
                if rel { p = CGPoint(x: cur.x + p.x, y: cur.y + p.y) }
                path.addLine(to: p); cur = p
            case "H":
                let x = num(); let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                path.addLine(to: p); cur = p
            case "V":
                let y = num(); let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                path.addLine(to: p); cur = p
            case "C":
                var c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num()), e = CGPoint(x: num(), y: num())
                if rel { c1 = add(cur, c1); c2 = add(cur, c2); e = add(cur, e) }
                path.addCurve(to: e, control1: c1, control2: c2); lastCubic = c2; cur = e
            case "S":
                var c2 = CGPoint(x: num(), y: num()), e = CGPoint(x: num(), y: num())
                if rel { c2 = add(cur, c2); e = add(cur, e) }
                let c1 = (prev == "C" || prev == "S") ? reflect(lastCubic, about: cur) : cur
                path.addCurve(to: e, control1: c1, control2: c2); lastCubic = c2; cur = e
            case "Q":
                var c = CGPoint(x: num(), y: num()), e = CGPoint(x: num(), y: num())
                if rel { c = add(cur, c); e = add(cur, e) }
                path.addQuadCurve(to: e, control: c); lastQuad = c; cur = e
            case "T":
                var e = CGPoint(x: num(), y: num())
                if rel { e = add(cur, e) }
                let c = (prev == "Q" || prev == "T") ? reflect(lastQuad, about: cur) : cur
                path.addQuadCurve(to: e, control: c); lastQuad = c; cur = e
            case "A":
                _ = num(); _ = num(); _ = num(); _ = num(); _ = num()   // rx ry xrot largeArc sweep
                var e = CGPoint(x: num(), y: num())
                if rel { e = add(cur, e) }
                path.addLine(to: e); cur = e               // arcs here are sub-pixel — line is exact enough
            case "Z":
                path.closeSubpath(); cur = start
            default:
                i += 1                                     // unknown — skip a char to stay safe
            }
            prev = Character(cmd.uppercased())
        }
        return path
    }

    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
}

// MARK: - Activation helpers

/// Builds `[MuscleGroup: Double]` (PRD §22 weighting: primary 1.0, secondary 0.5) from logged
/// strength data, so any surface can drive a `MuscleMapView` straight from a session/workouts.
enum MuscleActivation {
    static func from(session: StrengthSession) -> [MuscleGroup: Double] {
        let entries = session.exercises.map { row in
            (primary: (row.exercise?.primaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             secondary: (row.exercise?.secondaryMuscles ?? []).compactMap(MuscleGroup.init(rawValue:)),
             sets: row.sets.filter { $0.isComplete && $0.type == .working }.count)
        }
        return StrengthMath.weeklySetsByMuscle(entries)
    }

    /// Merge across multiple workouts (e.g. trailing-7-day weekly coverage).
    static func from(workouts: [Workout]) -> [MuscleGroup: Double] {
        var total: [MuscleGroup: Double] = [:]
        for workout in workouts {
            guard let session = workout.strength else { continue }
            for (muscle, value) in from(session: session) { total[muscle, default: 0] += value }
        }
        return total
    }

    /// Lower-body contribution from foot sports (running/walking/hiking) — endurance work drives the
    /// posterior chain, so the athlete figure reflects a runner's training, not only gym work. Scaled
    /// by distance in "set-equivalents per km" tuned to the panel's ABSOLUTE yardstick
    /// (`MuscleMapGrading.fullBurnWeeklySets` = 10): ~20 km of running a week burns the calves
    /// full, quads just behind, hamstrings and glutes lighter, core a touch. Walks/hikes count at
    /// half (same chain, lighter load).
    static func fromEndurance(workouts: [Workout]) -> [MuscleGroup: Double] {
        let perKm: [MuscleGroup: Double] = [.calves: 0.5, .quads: 0.45, .hamstrings: 0.35, .glutes: 0.35, .core: 0.15]
        var total: [MuscleGroup: Double] = [:]
        for w in workouts where w.type.category == .foot {
            let km = (w.gps?.distanceM ?? 0) / 1000
            guard km > 0 else { continue }
            let scale = w.type.discipline == .walking ? 0.5 : 1.0   // walk/hike lighter than run
            for (m, f) in perKm { total[m, default: 0] += f * km * scale }
        }
        return total
    }

    /// The Athlete Panel's activation: strength coverage plus the endurance lower-body contribution,
    /// so both a lifter and a pure runner see a figure that reflects — and re-windows with — their work.
    static func combined(workouts: [Workout]) -> [MuscleGroup: Double] {
        var total = from(workouts: workouts)
        for (m, v) in fromEndurance(workouts: workouts) { total[m, default: 0] += v }
        return total
    }

    /// The Athlete Panel's number: weekly working-set-equivalents per muscle over a trailing window
    /// — the in-window `combined` total ÷ the window's EXACT length in weeks. The figure grades
    /// this absolutely (`.weeklyVolume`), so the divisor is what makes 7D, 1M, 3M and 6M one
    /// yardstick. A 30-day window is 4.29 weeks; dividing by a whole 4 (the old integer
    /// `activationDays / 7`) read the same training ~7% brighter at 1M and 3M than at 7D, when the
    /// panel's own rule is "brighter only where the athlete actually trains more." Untrained
    /// muscles are simply absent — the figure leaves them unlit. Pure and unit-tested.
    static func weeklyRate(workouts: [Workout], days: Int, now: Date = Date()) -> [MuscleGroup: Double] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let weeks = max(1, Double(days) / 7)     // a sub-week window is never scaled UP
        return combined(workouts: workouts.filter { $0.startedAt >= cutoff }).mapValues { $0 / weeks }
    }
}

extension MuscleGroup {
    /// Display label: `fullBody` → "Full Body", `hamstrings` → "Hamstrings".
    var displayName: String {
        switch self {
        case .fullBody: return "Full Body"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

#Preview {
    ZStack {
        Color.white.ignoresSafeArea()
        MuscleMapView(activation: [.chest: 5, .triceps: 4, .shoulders: 3, .quads: 1, .core: 2, .back: 2])
            .padding(24)
    }
}
