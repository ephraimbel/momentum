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
            .frame(height: 52)
            .padding(.horizontal, Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(focused ? Theme.purple : Theme.hairline, lineWidth: focused ? 1.5 : 1)
            }
            .overlay {
                // A soft tint halo outside the hairline — focus you can see at a glance without a
                // hard second border. Lavender is the app's "happening now" accent, and a focused
                // field is precisely that.
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.purpleTint, lineWidth: 4)
                    .opacity(focused ? 1 : 0)
                    .blur(radius: 2)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
            .foregroundStyle(enabled ? Theme.background : Theme.inkTertiary)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    // Disabled is QUIET. Dimming the ink pill to 50% produced a mid-grey slab that
                    // was the loudest thing on the page — the eye went straight to the one control
                    // that could not be used.
                    .fill(enabled ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.ink.opacity(0.08)))
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled || inFlight)
        .animation(.easeOut(duration: 0.18), value: enabled)
    }
}
