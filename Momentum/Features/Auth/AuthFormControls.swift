import SwiftUI

/// The shared controls behind every auth form — the account page and the reset-link password
/// screen.
///
/// These were duplicated, and the two copies drifted exactly as duplicated chrome always does:
/// the same tap-target bug, the same grey-slab disabled button and the same undifferentiated
/// message styling existed in both, and fixing one left the other untouched. One definition means
/// the next fix lands everywhere by construction.
enum AuthMessageKind { case error, info }

extension View {
    /// The boxed field chrome: surface fill, hairline, and a lavender focus ring.
    ///
    /// ⚠️ The BOX is the tap target. Framing the text view and padding OUTSIDE it left a 16pt
    /// margin on each side that looked tappable and wasn't — the commonest way a form feels
    /// broken without anything visibly failing.
    func authFieldBox(focused: Bool, tap: @escaping () -> Void) -> some View {
        self
            .font(.rounded(Theme.FontSize.body, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(height: 56)
            .padding(.horizontal, 20)
            // A SUNKEN well, not the raised card material (owner call 2026-08-28). The fields
            // used to wear the same surface as the buttons beside them, so a thing you type into
            // looked like a thing you press. Depth is the affordance: raised = act, sunken = enter.
            // Focus = the lavender ring, the app's "happening now" accent.
            .sunken(.rounded(OnboardingStyle.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous)
                    .strokeBorder(Theme.purple, lineWidth: 1.5)
                    .opacity(focused ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius, style: .continuous))
            .onTapGesture(perform: tap)
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// One inline message treatment for every auth form: an icon so the state reads before the words
/// do, and `Theme.warning` for refusals — the brand has no alarm red.
///
/// ⚠️ `kind` is always set explicitly by whoever writes the message, never inferred from its text.
/// Sniffing the string mis-filed a successful sign-up's "we emailed you a link" as a failure.
struct AuthMessageRow: View {
    let text: String
    let kind: AuthMessageKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: kind == .error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
            Text(text)
                .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(kind == .error ? Theme.warning : Theme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/// The ink pill every auth form submits through.
struct AuthPrimaryButton: View {
    let title: String
    let enabled: Bool
    let inFlight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // The label stays mounted at zero opacity while the spinner runs: swapping it out
                // re-measured the pill mid-tap and the button twitched at the exact moment the
                // athlete was watching it.
                Text(title)
                    .font(.rounded(Theme.FontSize.body, weight: .bold))
                    .opacity(inFlight ? 0 : 1)
                if inFlight { ProgressView().tint(Theme.background) }
            }
            .foregroundStyle(enabled ? .white : Theme.inkTertiary)
            .frame(maxWidth: .infinity).frame(height: 58)
            // Enabled: the raised ink capsule every onboarding CTA wears. Disabled stays QUIET
            // (a flat 8% slab): dimming the ink pill to 50% produced a mid-grey slab that was the
            // loudest thing on the page.
            .modifier(AuthCTASurface(enabled: enabled))
        }
        .buttonStyle(RaisedPressStyle())
        .disabled(!enabled || inFlight)
        .animation(.easeOut(duration: 0.18), value: enabled)
    }
}

/// Raised ink when live; a flat quiet slab when not.
private struct AuthCTASurface: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.raised(Capsule(), tone: .ink) }
        else { content.background(Capsule().fill(Theme.ink.opacity(0.08))) }
    }
}
