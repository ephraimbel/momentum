import SwiftUI
import SwiftData

/// Exercise library as a picker sheet (PRD §4.5). Search by name, filter by muscle/equipment,
/// create a custom exercise. Calls `onSelect` with the chosen exercise and dismisses.
struct ExerciseLibraryView: View {
    var onSelect: (Exercise) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allExercises: [Exercise]

    @State private var search = ""
    @State private var muscleFilter: MuscleGroup?
    @State private var equipmentFilter: EquipmentType?
    @State private var showingCustom = false

    private var filtered: [Exercise] {
        allExercises
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .filter { ex in
                guard let m = muscleFilter?.rawValue else { return true }
                return ex.primaryMuscles.contains(m) || ex.secondaryMuscles.contains(m)
            }
            .filter { equipmentFilter == nil || $0.equipment == equipmentFilter }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                List {
                    ForEach(filtered) { exercise in
                        Button {
                            Haptics.selection()
                            onSelect(exercise)
                            dismiss()
                        } label: {
                            ExerciseRowLabel(exercise: exercise)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView("No exercises", systemImage: "magnifyingglass",
                                               description: Text("Try a different search or add a custom exercise."))
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingCustom = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingCustom) {
                CustomExerciseSheet { onSelect($0); dismiss() }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                Menu {
                    Button("All muscles") { muscleFilter = nil }
                    ForEach(MuscleGroup.allCases, id: \.self) { m in
                        Button(m.rawValue.capitalized) { muscleFilter = m }
                    }
                } label: {
                    FilterChipLabel(title: muscleFilter?.rawValue.capitalized ?? "Muscle",
                                    isActive: muscleFilter != nil)
                }
                Menu {
                    Button("All equipment") { equipmentFilter = nil }
                    ForEach(EquipmentType.allCases, id: \.self) { e in
                        Button(e.rawValue.capitalized) { equipmentFilter = e }
                    }
                } label: {
                    FilterChipLabel(title: equipmentFilter?.rawValue.capitalized ?? "Equipment",
                                    isActive: equipmentFilter != nil)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
    }
}

private struct ExerciseRowLabel: View {
    let exercise: Exercise
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(exercise.name)
                    .font(.system(size: Theme.FontSize.body, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if exercise.isCustom {
                    Text("Custom")
                        .font(.system(size: Theme.FontSize.label, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Text(subtitle)
                .font(.system(size: Theme.FontSize.caption))
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.vertical, 4)
    }
    private var subtitle: String {
        let muscles = exercise.primaryMuscles.map { $0.capitalized }.joined(separator: ", ")
        return "\(exercise.equipment.rawValue.capitalized) · \(muscles)"
    }
}

private struct FilterChipLabel: View {
    let title: String
    let isActive: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: Theme.FontSize.caption, weight: .medium))
        .foregroundStyle(isActive ? Theme.background : Theme.ink)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(isActive ? Theme.ink : Theme.surface)
            Capsule().stroke(Theme.hairline, lineWidth: 1)
        }
        .clipShape(Capsule())
    }
}

#Preview {
    ExerciseLibraryView { _ in }
        .modelContainer(PersistenceController.inMemory().container)
}
