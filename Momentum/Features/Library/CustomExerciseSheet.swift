import SwiftUI
import SwiftData

/// Create a custom exercise (PRD §4.5) — name + muscles + equipment + tracking mode. Inserts an
/// owned (`isCustom = true`) `Exercise` and returns it to the caller.
struct CustomExerciseSheet: View {
    var onCreate: (Exercise) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var primary: MuscleGroup = .chest
    @State private var equipment: EquipmentType = .barbell
    @State private var category: ExerciseCategory = .compound
    @State private var trackingMode: TrackingMode = .weightReps
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Cable Fly", text: $name)
                }
                Section("Details") {
                    Picker("Primary muscle", selection: $primary) {
                        ForEach(MuscleGroup.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Equipment", selection: $equipment) {
                        ForEach(EquipmentType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Type", selection: $category) {
                        ForEach(ExerciseCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Tracking", selection: $trackingMode) {
                        ForEach(TrackingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .navigationTitle("Custom Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Couldn't create the exercise", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Something went wrong writing to storage. Your details are still here — try Add again.")
            }
        }
    }

    private func create() {
        let ex = Exercise(name: name.trimmingCharacters(in: .whitespaces),
                          primaryMuscles: [primary], equipment: equipment,
                          category: category, trackingMode: trackingMode, isCustom: true)
        context.insert(ex)
        // Handing back an unsaved exercise would let the athlete log sets against a row that
        // vanishes on next launch — fail loudly and keep the form.
        do { try context.save() } catch {
            context.delete(ex)
            saveFailed = true
            return
        }
        Haptics.success()
        onCreate(ex)
        dismiss()
    }
}
