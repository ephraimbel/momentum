import SwiftUI

/// The Home Screen widget's face — shared by the widget extension (which wraps it in a
/// `StaticConfiguration`) and the app (which renders it in the `--widget-preview` harness so the
/// design can be screenshot-verified without choreographing the widget gallery).
///
/// Design language: the app's monochrome canvas with iridescence strictly earned — the only
/// gradient pixels are completed days on the week ribbon, the streak chip, and the done badge.
/// Space Grotesk carries the hero numeral, Inter carries the labels (both bundled in the
/// extension). Light is the white hero; dark is the warm charcoal.
struct TodayWidgetContent: View {
    enum Layout { case small, medium }

    let snapshot: WidgetSnapshot?
    let layout: Layout

    var body: some View {
        Group {
            if let snapshot {
                if snapshot.describesToday {
                    switch layout {
                    case .small: small(snapshot)
                    case .medium: medium(snapshot)
                    }
                } else {
                    dayRolled(snapshot)
                }
            } else {
                placeholder
            }
        }
    }

    // MARK: - Small: today up top, the week as a footer strip

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                microLabel(s.sessionDone ? "BANKED" : "TODAY")
                Spacer(minLength: 4)
                streakChip(s.streak)
            }
            Spacer(minLength: 8)
            heroBlock(s, compact: true)
            Spacer(minLength: 10)
            weekFooter(s.week, letters: true, todayRing: true)
        }
    }

    // MARK: - Medium: today on the left, the week as columns on the right

    private func medium(_ s: WidgetSnapshot) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                microLabel(s.sessionDone ? "BANKED" : "TODAY")
                Spacer(minLength: 8)
                heroBlock(s, compact: false)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(WidgetInk.hairline).frame(width: 0.5)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    microLabel("THIS WEEK")
                    Spacer(minLength: 4)
                    streakChip(s.streak)
                }
                Spacer(minLength: 0)
                ribbon(s.week, letters: true, todayRing: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Today's session

    @ViewBuilder
    private func heroBlock(_ s: WidgetSnapshot, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            if let title = s.sessionTitle {
                Text(title.uppercased())
                    .font(.custom("Inter-Bold", size: 10)).tracking(1.3)
                    .foregroundStyle(WidgetInk.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(s.sessionHero ?? title)
                        .font(.custom("SpaceGrotesk-Bold", size: compact ? 30 : 36)).monospacedDigit()
                        .foregroundStyle(WidgetInk.ink)
                        .lineLimit(1).minimumScaleFactor(0.55)
                    if s.sessionDone { doneBadge }
                }
                Text(s.sessionDone ? "In the bank. Recover well." : (s.sessionDetail ?? "Whenever you're ready."))
                    .font(.custom("Inter-SemiBold", size: 11.5))
                    .foregroundStyle(WidgetInk.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Text("REST DAY")
                    .font(.custom("Inter-Bold", size: 10)).tracking(1.3)
                    .foregroundStyle(WidgetInk.secondary)
                Text("Rest")
                    .font(.custom("SpaceGrotesk-Bold", size: compact ? 30 : 36))
                    .foregroundStyle(WidgetInk.ink)
                Text("It counts. That's the plan working.")
                    .font(.custom("Inter-SemiBold", size: 11.5))
                    .foregroundStyle(WidgetInk.secondary)
                    .lineLimit(2).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The earned checkmark — the widget's one loud iridescent moment, only after the work.
    private var doneBadge: some View {
        ZStack {
            Circle().fill(WidgetInk.iridescent)
            Circle().stroke(WidgetInk.ink.opacity(0.12), lineWidth: 0.5)
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(WidgetInk.inkFixedDark)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel("Completed")
    }

    // MARK: - The week ribbon (the signature)

    /// The small-widget footer: a hairline separates today from the week strip, so the ribbon
    /// reads as an intentional zone rather than floating dots.
    private func weekFooter(_ week: [WidgetSnapshot.DayMark], letters: Bool, todayRing: Bool) -> some View {
        VStack(spacing: 8) {
            Rectangle().fill(WidgetInk.hairline).frame(height: 0.5)
            ribbon(week, letters: letters, todayRing: todayRing)
        }
    }

    /// Seven marks, one week — the earned gradient on done days, a soft spotlight halo under today,
    /// a hairline ring for planned, a quiet dot for rest. Day letters sit above each mark.
    private func ribbon(_ week: [WidgetSnapshot.DayMark], letters: Bool, todayRing: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 5) {
                    if letters {
                        Text(day.letter.uppercased())
                            .font(.custom("Inter-Bold", size: 8.5)).tracking(0.3)
                            .foregroundStyle(day.isToday && todayRing ? WidgetInk.ink : WidgetInk.tertiary)
                    }
                    mark(day, todayRing: todayRing)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func mark(_ day: WidgetSnapshot.DayMark, todayRing: Bool) -> some View {
        ZStack {
            // Today gets a soft filled spotlight — a gentle presence, never a harsh ring.
            if day.isToday && todayRing {
                Circle().fill(WidgetInk.ink.opacity(0.07)).frame(width: 20, height: 20)
            }
            switch day.state {
            case .done:
                // The earned day: gradient fill with a whisper of glow.
                Circle().fill(WidgetInk.iridescent).frame(width: 11, height: 11)
                    .shadow(color: WidgetInk.glow, radius: 2.5)
                Circle().stroke(WidgetInk.ink.opacity(0.12), lineWidth: 0.5).frame(width: 11, height: 11)
            case .planned:
                Circle().stroke(WidgetInk.ink.opacity(0.32), lineWidth: 1.3).frame(width: 9, height: 9)
            case .rest:
                Circle().fill(WidgetInk.ink.opacity(0.18)).frame(width: 3.5, height: 3.5)
            }
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - The earned streak chip (hidden at zero — quiet until it exists)

    @ViewBuilder
    private func streakChip(_ streak: Int) -> some View {
        if streak > 0 {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill").font(.system(size: 8.5, weight: .bold))
                Text("\(streak)")
                    .font(.custom("SpaceGrotesk-Bold", size: 12.5)).monospacedDigit()
            }
            .foregroundStyle(WidgetInk.ink)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background {
                Capsule().fill(WidgetInk.iridescent).opacity(0.32)
                Capsule().stroke(WidgetInk.ink.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityLabel("\(streak) day streak")
        }
    }

    // MARK: - Edge states

    /// The snapshot is from an earlier day (the app hasn't opened yet today) — never show
    /// yesterday's session as if it were today's. The ribbon stays (it's still this week);
    /// the stale today-ring comes off.
    private func dayRolled(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                microLabel("TODAY")
                Spacer(minLength: 4)
                streakChip(s.streak)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready")
                    .font(.custom("SpaceGrotesk-Bold", size: layout == .small ? 30 : 36))
                    .foregroundStyle(WidgetInk.ink)
                Text("Open for today's session.")
                    .font(.custom("Inter-SemiBold", size: 11.5))
                    .foregroundStyle(WidgetInk.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 10)
            weekFooter(s.week, letters: true, todayRing: false)
        }
    }

    /// Never opened the app (or no plan yet) — the quiet brand invitation.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("momentum")
                .font(.custom("SpaceGrotesk-Bold", size: 17))
                .foregroundStyle(WidgetInk.ink)
            Text("Your plan lives here.\nOpen the app to get moving.")
                .font(.custom("Inter-SemiBold", size: 11))
                .foregroundStyle(WidgetInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Rectangle().fill(WidgetInk.hairline).frame(width: 44, height: 2).clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func microLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("Inter-Bold", size: 10)).tracking(1.4)
            .foregroundStyle(WidgetInk.tertiary)
            .lineLimit(1)
    }
}

/// The app's palette, hand-carried for the extension (it can't see `Theme`): white hero canvas by
/// day, warm charcoal (#1E1D1B) by night, near-black warm ink, and the earned iridescent stops.
enum WidgetInk {
    static let canvas = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 30 / 255, green: 29 / 255, blue: 27 / 255, alpha: 1)
            : UIColor.white
    })
    static let ink = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 26 / 255, green: 25 / 255, blue: 23 / 255, alpha: 1)
    })
    /// The done-badge glyph sits on a pastel gradient in BOTH appearances — fixed warm-dark ink.
    static let inkFixedDark = Color(red: 26 / 255, green: 25 / 255, blue: 23 / 255)
    static var secondary: Color { ink.opacity(0.55) }
    static var tertiary: Color { ink.opacity(0.40) }
    static var hairline: Color { ink.opacity(0.14) }
    /// The whisper of glow under an earned day — a lilac halo that reads in both appearances.
    static let glow = Color(red: 0.72, green: 0.62, blue: 1).opacity(0.5)

    /// The brand's holographic stops (Theme.iridescent), as the earned fill.
    static let iridescent = LinearGradient(
        colors: [Color(red: 184 / 255, green: 192 / 255, blue: 1),      // periwinkle
                 Color(red: 230 / 255, green: 194 / 255, blue: 1),      // lilac
                 Color(red: 194 / 255, green: 240 / 255, blue: 1)],     // ice
        startPoint: .topLeading, endPoint: .bottomTrailing)
}
