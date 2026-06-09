import SwiftUI

/// The activity chooser (PRD §4.2, §7.3): a calm sheet of Run · Ride · Walk · Strength. One tap
/// commits and routes to the right live experience.
struct ActivityChooserView: View {
    var onChoose: (WorkoutType) -> Void
    @Environment(\.dismiss) private var dismiss

    private let options: [WorkoutType] = [.run, .ride, .walk, .strength]

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.md) {
                ForEach(options) { type in
                    SelectionCard(title: type.title, systemImage: type.systemImage) {
                        onChoose(type)
                    }
                }
                Spacer()
            }
            .padding(Theme.Space.md)
            .background(Theme.background)
            .navigationTitle("Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

#Preview { ActivityChooserView { _ in } }
