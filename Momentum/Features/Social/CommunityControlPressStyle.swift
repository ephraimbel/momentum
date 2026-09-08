import SwiftUI

/// Quiet feedback for standalone controls. Mosaic tiles keep their existing dim-only feedback.
struct CommunityControlPressStyle: ButtonStyle {
    @ReducedMotionPreference private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
