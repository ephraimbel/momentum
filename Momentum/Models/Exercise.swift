import Foundation
import SwiftData

/// Exercise library entry — shared catalog (`isCustom == false`, read-only) or user custom
/// (`isCustom == true`). PRD §4.5 / §8.7 / §13.7.
@Model
final class Exercise {
    var id: UUID = UUID()
    var name: String = ""
    var primaryMuscles: [String] = []   // MuscleGroup raw values
    var secondaryMuscles: [String] = []
    var equipment: EquipmentType = EquipmentType.barbell
    var category: ExerciseCategory = ExerciseCategory.compound
    var trackingMode: TrackingMode = TrackingMode.weightReps
    var defaultRestS: Double = 120
    var instructions: String = ""
    var isCustom: Bool = false

    init() {}

    init(name: String,
         primaryMuscles: [MuscleGroup],
         secondaryMuscles: [MuscleGroup] = [],
         equipment: EquipmentType,
         category: ExerciseCategory,
         trackingMode: TrackingMode = .weightReps,
         defaultRestS: Double = 120,
         instructions: String = "",
         isCustom: Bool = false) {
        self.name = name
        self.primaryMuscles = primaryMuscles.map(\.rawValue)
        self.secondaryMuscles = secondaryMuscles.map(\.rawValue)
        self.equipment = equipment
        self.category = category
        self.trackingMode = trackingMode
        self.defaultRestS = defaultRestS
        self.instructions = instructions
        self.isCustom = isCustom
    }
}
