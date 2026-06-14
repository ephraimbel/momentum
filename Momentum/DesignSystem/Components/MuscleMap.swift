import SwiftUI

/// A human-body muscle map (PRD §4.4) — the strength counterpart to `IridescentOrb`. Anatomically
/// detailed front + back figures whose muscles glow with the **earned iridescent** accent, intensity
/// scaled by how much each muscle was worked. 100% Apple-native: real anatomical SVG paths (see
/// `MuscleBodyData`, MIT) are parsed into SwiftUI `Path`s at runtime — no map/UI SDKs, no bitmap art.
///
/// Drive it with a `[MuscleGroup: Double]` (e.g. `MuscleActivation` / `StrengthMath`): unworked
/// muscles read as a faint anatomy chart, worked muscles light up, the most-worked burns fullest and
/// the rest scale relative to it. Honors Reduce Motion (iridescence holds static via `IridescentView`).
struct MuscleMapView: View {
    let activation: [MuscleGroup: Double]
    /// Which figures to show, left→right. Default front + back (the iconic anatomy-chart look).
    var sides: [BodySide] = [.front, .back]

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
                BodyFigure(side: side, activation: resolved, maxVal: maxVal)
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

enum BodySide: String, Identifiable, CaseIterable { case front, back; var id: String { rawValue } }

// MARK: - One figure

private struct BodyFigure: View {
    let side: BodySide
    let activation: [MuscleGroup: Double]
    let maxVal: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parts: [BodyAnatomy.Part] { side == .front ? BodyAnatomy.front : BodyAnatomy.back }
    private var outline: Path { side == .front ? BodyAnatomy.frontOutline : BodyAnatomy.backOutline }
    private var originX: CGFloat { side == .front ? 0 : BodyAnatomy.viewBoxWidth }

    var body: some View {
        GeometryReader { geo in
            let lw = max(0.8, geo.size.width * 0.006)
            ZStack {
                // Unworked baseline — a quiet anatomy chart so the figure always reads.
                ForEach(parts.indices, id: \.self) { i in
                    shape(parts[i].path).fill(Theme.inkTertiary.opacity(0.11))
                }

                // Worked muscles: one flowing oil-slick, revealed only through worked regions, each at
                // an alpha proportional to its volume. (Mask alpha = per-muscle intensity.)
                IridescentView(intensity: 1.0, isStatic: reduceMotion)
                    .mask(
                        ZStack {
                            ForEach(parts.indices, id: \.self) { i in
                                let intensity = intensity(parts[i].muscle)
                                if intensity > 0 { shape(parts[i].path).fill(.white.opacity(intensity)) }
                            }
                        }
                    )

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
        .aspectRatio(BodyAnatomy.viewBoxWidth / BodyAnatomy.viewBoxHeight, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func shape(_ path: Path) -> ScaledBodyShape { ScaledBodyShape(source: path, originX: originX) }

    /// Worked → 0.55…1.0 (even a light muscle is clearly lit); unworked → 0.
    private func intensity(_ muscle: MuscleGroup?) -> Double {
        guard let muscle, let v = activation[muscle], v > 0, maxVal > 0 else { return 0 }
        return 0.55 + 0.45 * min(1, v / maxVal)
    }
}

/// Maps a parsed body `Path` (in source viewBox coords) onto the view, preserving aspect. Back-figure
/// paths live at x∈[724,1448]; `originX` shifts them back so each figure fills its own frame.
private struct ScaledBodyShape: Shape {
    let source: Path
    let originX: CGFloat
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / BodyAnatomy.viewBoxWidth
        let t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                  tx: rect.minX - originX * scale, ty: rect.minY)
        return source.applying(t)
    }
}

// MARK: - Parsed anatomy (slug → muscle, SVG path → SwiftUI Path), built once and cached

enum BodyAnatomy {
    static let viewBoxWidth: CGFloat = 724
    static let viewBoxHeight: CGFloat = 1448

    struct Part { let muscle: MuscleGroup?; let path: Path }

    static let front: [Part] = build(MuscleBodyData.front, map: frontMuscle)
    // Back `head` is a wide hairline shape (the source strokes it as a thin line); as a fill it
    // smears grey outside the cranium, which `hair` + the outline already render cleanly. Drop it.
    static let back: [Part] = build(MuscleBodyData.back, map: backMuscle, skip: ["head"])
    static let frontOutline: Path = SVGPath.parse(MuscleBodyData.frontOutline)
    static let backOutline: Path = SVGPath.parse(MuscleBodyData.backOutline)

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
