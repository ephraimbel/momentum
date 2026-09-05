import SwiftUI

/// The one @handle editor — used by the onboarding identity step and Edit Profile so claiming
/// and changing a handle look and behave identically. Live normalization on every keystroke
/// (SocialPrivacy.normalizedHandle), a debounced advisory availability probe (works for guests —
/// anon RPC), and tap-to-use suggestions when the handle is taken. Availability here is UX only;
/// the database's unique index is the arbiter at claim time.
struct HandleField: View {
    @Binding var handle: String
    let backend: any SocialBackending
    /// Extra candidates offered when the current handle is taken (tap to use).
    var suggestions: [String] = []
    /// Standalone card chrome (onboarding). Off when embedded in an editor card (Edit Profile).
    var boxed: Bool = false
    /// Onboarding shows a gentle hint when checks can't run (guest offline); Edit Profile stays quiet.
    var showsOfflineHint: Bool = false
    var onAvailabilityChange: ((Availability) -> Void)? = nil

    enum Availability: Equatable { case idle, checking, available, taken, reserved, unknown }
    @State private var availability: Availability = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: 2) {
                Text("@")
                    .font(.rounded(Theme.FontSize.body, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                TextField("handle", text: $handle)
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .onChange(of: handle) { _, new in
                        let normalized = SocialPrivacy.normalizedHandle(new)
                        if normalized != new { handle = normalized }
                    }
                    .accessibilityLabel("Handle")
                statusIcon
            }
            .padding(.horizontal, boxed ? 20 : 0)
            .padding(.vertical, boxed ? 18 : 12)
            .modifier(BoxedRaise(on: boxed))
            statusLine
        }
        .task(id: handle) { await check() }
        .onChange(of: availability) { _, state in onAvailabilityChange?(state) }
    }

    // MARK: Status

    @ViewBuilder
    private var statusIcon: some View {
        switch availability {
        case .idle, .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small).tint(Theme.inkTertiary)
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.success)
                .accessibilityLabel("Handle available")
        case .taken, .reserved:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityLabel("Handle unavailable")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch availability {
        case .taken:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Taken — try one of these:")
                    .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
                if !openSuggestions.isEmpty {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(openSuggestions, id: \.self) { candidate in
                            Button {
                                handle = candidate
                                Haptics.selection()
                            } label: {
                                Text("@\(candidate)")
                                    .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, Theme.Space.sm).padding(.vertical, 5)
                                    .raised(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        case .reserved:
            Text("That one's reserved.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        case .unknown where showsOfflineHint && !handle.isEmpty:
            Text("We'll confirm it's free when you're online.")
                .font(.rounded(Theme.FontSize.label, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        default:
            EmptyView()
        }
    }

    private var openSuggestions: [String] {
        Array(suggestions.filter { $0 != handle }.prefix(3))
    }

    // MARK: Debounced advisory check (.task(id:) cancellation = the debounce)

    private func check() async {
        let current = SocialPrivacy.normalizedHandle(handle)
        guard !current.isEmpty else { availability = .idle; return }
        if SocialPrivacy.isReservedHandle(current) { availability = .reserved; return }
        availability = .checking
        guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
        let result = await backend.handleAvailability(current)
        guard !Task.isCancelled, SocialPrivacy.normalizedHandle(handle) == current else { return }
        switch result {
        case .some(true): availability = .available
        case .some(false): availability = .taken
        case .none: availability = .unknown
        }
    }
}

/// The boxed handle field wears the app's raised white material (glass pass 2026-08-27);
/// the inline variant stays bare.
private struct BoxedRaise: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.raised(RoundedRectangle(cornerRadius: 20, style: .continuous)) } else { content }
    }
}
