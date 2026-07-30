import SwiftUI
import UIKit

/// The athlete's appearance choice (Settings → Appearance). Both palettes are first-class: the
/// light look is the daylight hero (white canvas, near-black ink), the dark look is the original
/// true-black night aesthetic — same tokens, same iridescent earned accents, deeper stage.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let storageKey = "com.momentum.appearance"

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The UIKit twin of `colorScheme`, for the window-level override in `MomentumApp` —
    /// `.unspecified` IS the System case (it hands control back to the OS), which is what lets the
    /// applicator stay value-driven with no conditional structure.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// nil = follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
