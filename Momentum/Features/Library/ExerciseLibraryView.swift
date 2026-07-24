import SwiftUI
import SwiftData

/// Exercise library as a multi-select picker sheet (PRD §4.5). Search by name, filter by
/// muscle/equipment, tap to select several, create a custom exercise. On Done it returns the chosen
/// exercises in the order they were picked.
struct ExerciseLibraryView: View {
    var onSelect: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var allExercises: [Exercise]

    @State private var search = ""
    @State private var muscleFilter: MuscleGroup?
    @State private var equipmentFilter: EquipmentType?
    @State private var showingCustom = false
    @State private var picked: [Exercise] = []

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

    private func isPicked(_ e: Exercise) -> Bool {
        picked.contains { $0.persistentModelID == e.persistentModelID }
    }

    private func toggle(_ e: Exercise) {
        if let i = picked.firstIndex(where: { $0.persistentModelID == e.persistentModelID }) {
            picked.remove(at: i)
        } else {
            picked.append(e)
        }
    }

    private func commit() {
        guard !picked.isEmpty else { return }
        onSelect(picked)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                List {
                    ForEach(filtered) { exercise in
                        Button {
                            Haptics.selection()
                            withAnimation(.easeOut(duration: Motion.fast)) { toggle(exercise) }
                        } label: {
                            ExerciseRowLabel(exercise: exercise, isSelected: isPicked(exercise))
                        }
                        .buttonStyle(.plain)
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
            .navigationTitle("Add Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") { commit() }
                        .fontWeight(.semibold)
                        .disabled(picked.isEmpty)
                }
            }
            .sheet(isPresented: $showingCustom) {
                CustomExerciseSheet { ex in withAnimation(.easeOut(duration: Motion.fast)) { picked.append(ex) } }
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
                Button { showingCustom = true } label: {
                    FilterChipLabel(title: "New", isActive: false, systemImage: "plus")
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
        }
    }
}

private struct ExerciseRowLabel: View {
    let exercise: Exercise
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(exercise.name)
                        .font(.rounded(Theme.FontSize.body, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    if exercise.isCustom {
                        Text("Custom")
                            .font(.rounded(Theme.FontSize.label, weight: .bold))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                }
                Text(subtitle)
                    .font(.rounded(Theme.FontSize.caption, weight: .medium))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? Theme.ink : Theme.hairline)
                .symbolEffect(.bounce, value: isSelected)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let muscles = exercise.primaryMuscles.map { $0.capitalized }.joined(separator: ", ")
        return "\(exercise.equipment.rawValue.capitalized) · \(muscles)"
    }
}

private struct FilterChipLabel: View {
    let title: String
    let isActive: Bool
    var systemImage: String = "chevron.down"

    var body: some View {
        HStack(spacing: 4) {
            if systemImage == "plus" {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(title)
            } else {
                Text(title)
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
        }
        .font(.rounded(Theme.FontSize.caption, weight: .semibold))
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
