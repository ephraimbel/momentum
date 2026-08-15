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
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.sm) {
                Text("You're signed in from the recovery link. Choose a new password for next time.")
                    .font(.rounded(Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Theme.Space.sm)

                box {
                    if Self.uiTestPlainFields {
                        TextField("New password", text: $password)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused)
                    } else {
                        SecureField("New password", text: $password).textContentType(.newPassword).focused($focused)
                    }
                }
                box {
                    if Self.uiTestPlainFields {
                        TextField("Confirm password", text: $confirm)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        SecureField("Confirm password", text: $confirm).textContentType(.newPassword)
                    }
                }

                if let message {
                    Text(message)
                        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    save()
                } label: {
                    Group {
                        if inFlight {
                            ProgressView().tint(Theme.background)
                        } else {
                            Text("Save password").font(.rounded(Theme.FontSize.body, weight: .bold))
                        }
                    }
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.ink))
                }
                .buttonStyle(.plain)
                .disabled(inFlight || password.isEmpty || confirm.isEmpty)
                .opacity(password.isEmpty || confirm.isEmpty ? 0.5 : 1)
                .padding(.top, Theme.Space.xs)

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
                        .tint(Theme.ink)
                }
            }
            .onAppear { focused = true }
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

    private func box<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.rounded(Theme.FontSize.body, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(height: 52)
            .padding(.horizontal, Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(Theme.hairline))
    }

    private func save() {
        guard password == confirm else { message = "Those passwords don't match."; return }
        guard password.count >= 8 else { message = "Passwords need at least 8 characters."; return }
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
            }
        }
    }
}

#Preview {
    SetNewPasswordView().environment(AuthController(userID: "preview"))
}
