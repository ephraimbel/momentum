import SwiftUI
import UIKit

/// A numeral you can tap to TYPE (owner ask 2026-07-30: steppers are nice, "but they should also
/// be able to press on the number and just type in whatever they got"). Renders exactly like the
/// static display numeral it replaces; tapping swaps it for a focused numeric field whose
/// placeholder is the current value, and losing focus (or the keyboard's Done) commits.
///
/// Parsing/clamping stays at the CALL SITE via `commit` — this view knows how to look like a
/// momentum numeral and capture digits, not what a legal marathon time is. An empty or garbage
/// entry simply commits nothing and the old value stands.
struct TypableNumber: View {
    /// The formatted current value ("5′8″", "22:30", "165 lb").
    let display: String
    var keyboard: UIKeyboardType = .numberPad
    var minWidth: CGFloat = 76
    /// UI-test handle, applied to both faces (the numeral Button and the editing TextField) — a
    /// TextField's XCUITest label is its placeholder only while empty, so tests need an identifier.
    var axID: String? = nil
    /// Called with the raw typed text on commit; parse, clamp, and store there.
    var commit: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(display, text: $text)
                    .keyboardType(keyboard)
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(.display(20, weight: .black)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: minWidth)
                    .submitLabel(.done)
                    .onSubmit { focused = false }
                    // Number pads have no return key — give the keyboard an explicit Done.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }.fontWeight(.semibold)
                        }
                    }
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused { commitAndClose() }
                    }
                    // Commit LIVE on every keystroke, not only on blur: a save button tapped while
                    // the field still holds focus would otherwise read the stale pre-edit value
                    // (blur and button-action order isn't guaranteed). Each keystroke re-commits
                    // the full text, so the last one always wins with the complete entry.
                    .onChange(of: text) { _, now in
                        let typed = now.trimmingCharacters(in: .whitespaces)
                        if !typed.isEmpty { commit(typed) }
                    }
                    .onAppear {
                        text = ""
                        // Next runloop: focusing during the same transaction the field appears in
                        // is dropped on iOS more often than not.
                        DispatchQueue.main.async { focused = true }
                    }
                    .accessibilityIdentifier(axID ?? "")
            } else {
                Button {
                    Haptics.light()
                    editing = true
                } label: {
                    Text(display)
                        .font(.display(20, weight: .black)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: minWidth)
                        .contentTransition(.numericText())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to type a value")
                .accessibilityIdentifier(axID ?? "")
            }
        }
    }

    private func commitAndClose() {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { commit(typed) }
        editing = false
    }
}
