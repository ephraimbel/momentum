import SwiftUI

/// Presented after the athlete opens a password-recovery link (momentum://auth-callback with
/// type=recovery): the link signs them in, this sheet sets the new password. Skippable — the
/// recovery session is already valid, so closing it just keeps them signed in.
struct SetNewPasswordView: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var inFlight = false
    @State private var message: String?
    @State private var messageKind: AuthMessageKind = .error
    @State private var reveal = false
    @FocusState private var focused: Field?
    private enum Field { case password, confirm }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.sm) {
                Text("You're signed in from the recovery link. Choose a new password for next time.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Theme.Space.sm)

                HStack(spacing: Theme.Space.sm) {
                    Group {
                        if Self.uiTestPlainFields || reveal {
                            TextField("New password", text: $password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            SecureField("New password", text: $password).textContentType(.newPassword)
                        }
                    }
                    .focused($focused, equals: .password)
                    if !Self.uiTestPlainFields, !password.isEmpty {
                        Button {
                            reveal.toggle()
                            focused = .password
                        } label: {
                            Image(systemName: reveal ? "eye.slash" : "eye")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.inkTertiary)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(reveal ? "Hide password" : "Show password")
                    }
                }
                .authFieldBox(focused: focused == .password, tap: { focused = .password })

                Group {
                    if Self.uiTestPlainFields || reveal {
                        TextField("Confirm password", text: $confirm)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        SecureField("Confirm password", text: $confirm).textContentType(.newPassword)
                    }
                }
                .focused($focused, equals: .confirm)
                .authFieldBox(focused: focused == .confirm, tap: { focused = .confirm })

                // Stated before it can be broken, exactly as on the account page.
                if message == nil {
                    Text("At least 8 characters.")
                        .font(.rounded(Theme.FontSize.caption, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message { AuthMessageRow(text: message, kind: messageKind) }

                AuthPrimaryButton(title: "Save password",
                                  enabled: !password.isEmpty && !confirm.isEmpty,
                                  inFlight: inFlight,
                                  action: save)
                    .padding(.top, Theme.Space.sm)

                Spacer()
            }
            .padding(Theme.Space.xl)
            .background(Theme.background)
            .navigationTitle("New password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .font(.rounded(Theme.FontSize.body, weight: .semibold))
                }
            }
            .onAppear { focused = .password }
        }
    }

    /// Same UI-test escape hatch as SignInView: secure fields trip iOS AutoFill panels that
    /// XCUITest can't dismiss, so tests get plain fields (DEBUG-only, real athletes never do).
    private static var uiTestPlainFields: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--uitest-password")
        #else
        false
        #endif
    }

    private func save() {
        guard password == confirm else {
            message = "Those passwords don't match."; messageKind = .error; return
        }
        guard password.count >= 8 else {
            message = "Passwords need at least 8 characters."; messageKind = .error; return
        }
        message = nil
        inFlight = true
        Task {
            let ok = await auth.updatePassword(password)
            inFlight = false
            if ok {
                Haptics.success()
                dismiss()
            } else {
                message = "Couldn't update the password. Try again in a moment."
                messageKind = .error
            }
        }
    }
}

#Preview {
    SetNewPasswordView().environment(AuthController(userID: "preview"))
}
