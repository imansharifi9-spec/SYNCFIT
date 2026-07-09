import Foundation

struct CoachRoutineTemplateExercise: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var muscleGroup: String
    var setCount: Int
    var reps: Int
    var weight: Double?

    init(
        id: UUID = UUID(),
        name: String,
        muscleGroup: String,
        setCount: Int = 3,
        reps: Int = 8,
        weight: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
        self.setCount = max(setCount, 1)
        self.reps = max(reps, 1)
        self.weight = weight
    }

    init(from item: RoutineExerciseItem) {
        self.id = item.id
        self.name = item.exercise.name
        self.muscleGroup = item.exercise.muscleGroup
        self.setCount = item.plannedSetCount
        self.reps = item.plannedReps
        self.weight = item.plannedWeight
    }

    func asRoutineExerciseItem(sortOrder: Int) -> RoutineExerciseItem {
        RoutineExerciseItem(
            id: id,
            exercise: ProgramTemplateLibrary.resolveExercise(named: name),
            sortOrder: sortOrder,
            plannedSetCount: setCount,
            plannedReps: reps,
            plannedWeight: weight
        )
    }
}

struct CoachRoutineTemplateDay: Identifiable, Codable, Hashable {
    let id: UUID
    var weekday: Int
    var dayLabel: String
    var isRest: Bool
    var exercises: [CoachRoutineTemplateExercise]

    init(
        id: UUID = UUID(),
        weekday: Int,
        dayLabel: String,
        isRest: Bool = false,
        exercises: [CoachRoutineTemplateExercise] = []
    ) {
        self.id = id
        self.weekday = weekday
        self.dayLabel = dayLabel
        self.isRest = isRest
        self.exercises = exercises
    }

    func asWorkoutRoutine() -> WorkoutRoutine {
        let items = exercises.enumerated().map { index, exercise in
            exercise.asRoutineExerciseItem(sortOrder: index)
        }
        return WorkoutRoutine(name: dayLabel, exercises: items)
    }

    mutating func applyWorkoutRoutine(_ routine: WorkoutRoutine) {
        dayLabel = routine.name
        exercises = routine.sortedExercises.map(CoachRoutineTemplateExercise.init(from:))
        isRest = routine.exercises.isEmpty
    }
}

struct CoachRoutineTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var days: [CoachRoutineTemplateDay]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        days: [CoachRoutineTemplateDay],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.days = days
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var trainingDayCount: Int {
        days.filter { !$0.isRest && !$0.exercises.isEmpty }.count
    }

    var summaryText: String {
        let training = days.filter { !$0.isRest && !$0.exercises.isEmpty }
        guard !training.isEmpty else { return "No training days configured" }
        let labels = training.map(\.dayLabel).prefix(3).joined(separator: " · ")
        return "\(training.count) days/week — \(labels)"
    }

    var chatPreviewText: String {
        "Sent you a routine: \(name)"
    }

    func asProgramTemplate() -> ProgramTemplate {
        let programDays = days.map { day in
            ProgramTemplateDaySpec(
                weekday: day.weekday,
                routineName: day.dayLabel,
                exercises: day.exercises.map {
                    ProgramTemplateExerciseSpec(name: $0.name, setCount: $0.setCount, reps: $0.reps)
                },
                isRest: day.isRest || day.exercises.isEmpty
            )
        }
        return ProgramTemplate(
            id: id.uuidString,
            name: name,
            description: summaryText,
            difficulty: .beginner,
            daysPerWeek: max(trainingDayCount, 1),
            goal: .both,
            days: programDays
        )
    }

    static func blank() -> CoachRoutineTemplate {
        CoachRoutineTemplate(name: "", days: normalizedWeekdays(from: []))
    }

    /// Ensures all seven weekdays exist in Monday→Sunday order.
    static func normalizedWeekdays(from days: [CoachRoutineTemplateDay]) -> [CoachRoutineTemplateDay] {
        let byWeekday = Dictionary(uniqueKeysWithValues: days.map { ($0.weekday, $0) })
        return WorkoutWeekSchedule.mondayFirstDisplay.map { item in
            if let existing = byWeekday[item.weekday] {
                return existing
            }
            return CoachRoutineTemplateDay(
                weekday: item.weekday,
                dayLabel: WorkoutWeekSchedule.dayAbbreviation(forWeekday: item.weekday)
            )
        }
    }
}

struct RoutineCardPayload: Codable, Equatable {
    let template: CoachRoutineTemplate
    let coachNote: String?
    var implementedAt: Date?

    var isImplemented: Bool {
        implementedAt != nil
    }
}
