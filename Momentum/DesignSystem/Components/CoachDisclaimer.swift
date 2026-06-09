import SwiftUI

/// A quiet, persistent reminder that coaching is personalized guidance, not clinical advice
/// (research: AI-health trust requires a visible non-medical disclaimer — and citing "your data"
/// reinforces the personal-mirror voice). Tertiary and tiny: present, never nagging.
struct CoachDisclaimer: View {
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        Text("Guidance from your data, not medical advice.")
            .font(.rounded(Theme.FontSize.label, weight: .medium))
            .foregroundStyle(Theme.inkTertiary)
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
            .accessibilityLabel("This is personalized guidance from your data, not medical advice.")
    }
}
