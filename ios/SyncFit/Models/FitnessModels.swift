import Foundation
import SwiftData

@Model
final class MealComponentRecord {
    var id: UUID
    var name: String
    var amount: String
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var savedMeal: SavedMealRecord?

    init(
        id: UUID = UUID(),
        name: String,
        amount: String = "",
        calories: Int,
        protein: Int,
        carbs: Int,
        fat: Int
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }
}

@Model
final class SavedMealRecord {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \MealComponentRecord.savedMeal)
    var components: [MealComponentRecord]

    init(id: UUID = UUID(), name: String, components: [MealComponentRecord] = []) {
        self.id = id
        self.name = name
        self.components = components
        for component in components {
            component.savedMeal = self
        }
    }
}

@Model
final class RoutineExerciseRecord {
    /// Sentinel used during lightweight migration for rows created before routineID existed.
    static let unassignedRoutineID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var id: UUID
    var routineID: UUID = RoutineExerciseRecord.unassignedRoutineID
    var exerciseName: String
    var muscleGroup: String
    var sortOrder: Int
    var plannedSetCount: Int = 3
    var plannedReps: Int = 8
    var plannedWeight: Double?
    var plannedSetsJSON: String = ""
    var routine: WorkoutRoutineRecord?

    init(
        id: UUID = UUID(),
        routineID: UUID = RoutineExerciseRecord.unassignedRoutineID,
        exerciseName: String,
        muscleGroup: String,
        sortOrder: Int,
        plannedSetCount: Int = 3,
        plannedReps: Int = 8,
        plannedWeight: Double? = nil,
        plannedSetsJSON: String = ""
    ) {
        self.id = id
        self.routineID = routineID
        self.exerciseName = exerciseName
        self.muscleGroup = muscleGroup
        self.sortOrder = sortOrder
        self.plannedSetCount = plannedSetCount
        self.plannedReps = plannedReps
        self.plannedWeight = plannedWeight
        self.plannedSetsJSON = plannedSetsJSON
    }

    var needsRoutineIDBackfill: Bool {
        routineID == Self.unassignedRoutineID
    }
}

@Model
final class WorkoutRoutineRecord {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \RoutineExerciseRecord.routine)
    var exercises: [RoutineExerciseRecord]

    init(id: UUID = UUID(), name: String, exercises: [RoutineExerciseRecord] = []) {
        self.id = id
        self.name = name
        self.exercises = exercises
        for exercise in exercises {
            exercise.routine = self
            exercise.routineID = id
        }
    }
}

@Model
final class ExerciseRecord {
    var id: UUID
    var name: String
    var muscleGroup: String

    init(id: UUID = UUID(), name: String, muscleGroup: String) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
    }
}

@Model
final class WorkoutRecord {
    var id: UUID
    var exerciseName: String
    var muscleGroup: String
    var date: Date
    var notes: String
    var plannedSetsJSON: String = ""
    @Relationship(deleteRule: .cascade, inverse: \WorkoutSetRecord.workout)
    var sets: [WorkoutSetRecord]

    init(
        id: UUID = UUID(),
        exerciseName: String,
        muscleGroup: String,
        date: Date = .now,
        notes: String = "",
        plannedSetsJSON: String = "",
        sets: [WorkoutSetRecord] = []
    ) {
        self.id = id
        self.exerciseName = exerciseName
        self.muscleGroup = muscleGroup
        self.date = date
        self.notes = notes
        self.plannedSetsJSON = plannedSetsJSON
        self.sets = sets
        for set in sets {
            set.workout = self
        }
    }
}

@Model
final class WorkoutSetRecord {
    var id: UUID
    var reps: Int
    var weight: Double
    var rpe: Int?
    var workout: WorkoutRecord?

    init(id: UUID = UUID(), reps: Int, weight: Double, rpe: Int? = nil) {
        self.id = id
        self.reps = reps
        self.weight = weight
        self.rpe = rpe
    }
}

@Model
final class FoodRecord {
    var id: UUID
    var name: String
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var mealRaw: String
    var date: Date
    var servingLabel: String

    init(
        id: UUID = UUID(),
        name: String,
        calories: Int,
        protein: Int,
        carbs: Int,
        fat: Int,
        meal: MealType,
        date: Date = .now,
        servingLabel: String = ""
    ) {
        self.id = id
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.mealRaw = meal.rawValue
        self.date = date
        self.servingLabel = servingLabel
    }

    var meal: MealType {
        get { MealType(rawValue: mealRaw) ?? .snack }
        set { mealRaw = newValue.rawValue }
    }
}

@Model
final class WeightRecord {
    var id: UUID
    var weight: Double
    var date: Date

    init(id: UUID = UUID(), weight: Double, date: Date = .now) {
        self.id = id
        self.weight = weight
        self.date = date
    }
}

@Model
final class ProgressPhotoRecord {
    var id: UUID
    var date: Date
    var fileName: String
    var userId: String

    init(
        id: UUID = UUID(),
        date: Date = .now,
        fileName: String,
        userId: String = ProgressPhotoStorage.localUserId
    ) {
        self.id = id
        self.date = date
        self.fileName = fileName
        self.userId = userId
    }
}

@Model
final class CoachRecord {
    var id: UUID
    var name: String
    var specialty: String
    var pricePerMonth: Int
    var isOnline: Bool
    var rating: Double
    var bio: String
    var clientCount: Int = 0
    var reviewCount: Int = 0
    var isVerified: Bool = true
    var availabilityRaw: String = CoachAvailability.online.rawValue
    var location: String = ""
    var specialtiesJSON: String = ""
    var reviewsJSON: String = ""
    var photoFileName: String?
    var transformationPhotosJSON: String = ""
    var isLive: Bool = true

    init(
        id: UUID = UUID(),
        name: String,
        specialty: String,
        pricePerMonth: Int,
        isOnline: Bool,
        rating: Double,
        bio: String,
        clientCount: Int = 0,
        reviewCount: Int = 0,
        isVerified: Bool = true,
        availability: CoachAvailability = .online,
        location: String = "",
        specialties: [String] = [],
        reviews: [CoachReview] = [],
        photoFileName: String? = nil,
        transformationPhotoFileNames: [String] = [],
        isLive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.specialty = specialty
        self.pricePerMonth = pricePerMonth
        self.isOnline = isOnline
        self.rating = rating
        self.bio = bio
        self.clientCount = clientCount
        self.reviewCount = reviewCount
        self.isVerified = isVerified
        self.availabilityRaw = availability.rawValue
        self.location = location
        self.specialtiesJSON = Self.encodeJSON(specialties)
        self.reviewsJSON = Self.encodeJSON(reviews)
        self.photoFileName = photoFileName
        self.transformationPhotosJSON = Self.encodeJSON(transformationPhotoFileNames)
        self.isLive = isLive
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(type, from: data) else { return nil }
        return value
    }
}

@Model
final class AppSettings {
    var id: UUID
    var isAuthenticated: Bool
    var hasCompletedOnboarding: Bool
    var profileName: String
    var goalRaw: String
    var experienceRaw: String
    var hasCoach: Bool
    var calorieTarget: Int
    var proteinTarget: Int
    var carbTarget: Int
    var fatTarget: Int
    var appearanceRaw: String = AppAppearance.dark.rawValue
    var genderRaw: String = Gender.preferNotToSay.rawValue
    var birthday: Date = Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now
    var heightCm: Double = 175
    var bodyWeightKg: Double = 75
    var measurementSystemRaw: String = MeasurementSystem.imperial.rawValue
    var activityLevelRaw: String = ActivityLevel.moderatelyActive.rawValue
    var isSyncFitPlusSubscriber: Bool = false
    var workoutScheduleJSON: String = ""
    var sessionLabelsJSON: String = ""
    var dayTemplateAssignmentsJSON: String = ""
    var dayTemplateKindsJSON: String = ""
    var suppressDayTemplateAutoSeed: Bool = false
    var completedWorkoutDaysJSON: String = ""
    var exerciseNotesJSON: String = ""
    var restTimerSeconds: Int = 90
    var hasCompletedProgramSetup: Bool = false
    var nutritionMacroDisplayStyleRaw: String = NutritionMacroDisplayStyle.bars.rawValue
    var appleHealthSyncEnabled: Bool = false
    var coachModeActive: Bool = false
    var userIsCoach: Bool = false
    var coachPortalProfileJSON: String = ""
    var coachSessionID: String = ""
    var hiredCoachID: String = ""

    init(
        id: UUID = UUID(),
        isAuthenticated: Bool = false,
        hasCompletedOnboarding: Bool = false,
        profile: UserProfile = UserProfile(),
        appearance: AppAppearance = .dark
    ) {
        self.id = id
        self.isAuthenticated = isAuthenticated
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.profileName = profile.name
        self.goalRaw = profile.goal.rawValue
        self.experienceRaw = profile.experienceLevel.rawValue
        self.hasCoach = profile.hasCoach
        self.genderRaw = profile.gender.rawValue
        self.birthday = profile.birthday
        self.heightCm = profile.heightCm
        self.bodyWeightKg = profile.bodyWeightKg
        self.measurementSystemRaw = profile.measurementSystem.rawValue
        self.activityLevelRaw = profile.activityLevel.rawValue
        self.calorieTarget = profile.calorieTarget
        self.proteinTarget = profile.proteinTarget
        self.carbTarget = profile.carbTarget
        self.fatTarget = profile.fatTarget
        self.appearanceRaw = appearance.rawValue
    }

    var appearance: AppAppearance {
        get { AppAppearance.resolved(from: appearanceRaw) }
        set { appearanceRaw = newValue.rawValue }
    }

    var nutritionMacroDisplayStyle: NutritionMacroDisplayStyle {
        get { NutritionMacroDisplayStyle(rawValue: nutritionMacroDisplayStyleRaw) ?? .bars }
        set { nutritionMacroDisplayStyleRaw = newValue.rawValue }
    }

    var profile: UserProfile {
        get {
            UserProfile(
                name: profileName,
                goal: FitnessGoal.fromStored(goalRaw),
                experienceLevel: ExperienceLevel(rawValue: experienceRaw) ?? .beginner,
                hasCoach: hasCoach,
                gender: Gender(rawValue: genderRaw) ?? .preferNotToSay,
                birthday: birthday,
                heightCm: heightCm,
                bodyWeightKg: bodyWeightKg,
                measurementSystem: MeasurementSystem(rawValue: measurementSystemRaw) ?? .imperial,
                activityLevel: ActivityLevel(rawValue: activityLevelRaw) ?? .moderatelyActive,
                calorieTarget: calorieTarget,
                proteinTarget: proteinTarget,
                carbTarget: carbTarget,
                fatTarget: fatTarget
            )
        }
        set {
            profileName = newValue.name
            goalRaw = newValue.goal.rawValue
            experienceRaw = newValue.experienceLevel.rawValue
            hasCoach = newValue.hasCoach
            genderRaw = newValue.gender.rawValue
            birthday = newValue.birthday
            heightCm = newValue.heightCm
            bodyWeightKg = newValue.bodyWeightKg
            measurementSystemRaw = newValue.measurementSystem.rawValue
            activityLevelRaw = newValue.activityLevel.rawValue
            calorieTarget = newValue.calorieTarget
            proteinTarget = newValue.proteinTarget
            carbTarget = newValue.carbTarget
            fatTarget = newValue.fatTarget
        }
    }
}

extension ExerciseRecord {
    var asExercise: Exercise {
        Exercise(id: id, name: name, muscleGroup: muscleGroup)
    }

    convenience init(from exercise: Exercise) {
        self.init(id: exercise.id, name: exercise.name, muscleGroup: exercise.muscleGroup)
    }
}

extension WorkoutRecord {
    var asEntry: WorkoutEntry {
        WorkoutEntry(
            id: id,
            exercise: Exercise(name: exerciseName, muscleGroup: muscleGroup),
            sets: sets.map { $0.asSet },
            plannedSets: Self.decodePlannedSets(from: plannedSetsJSON),
            date: date,
            notes: notes
        )
    }

    convenience init(from entry: WorkoutEntry) {
        let setRecords = entry.sets.map { WorkoutSetRecord(from: $0) }
        self.init(
            id: entry.id,
            exerciseName: entry.exercise.name,
            muscleGroup: entry.exercise.muscleGroup,
            date: entry.date,
            notes: entry.notes,
            plannedSetsJSON: Self.encodePlannedSets(entry.plannedSets),
            sets: setRecords
        )
    }

    static func encodePlannedSets(_ sets: [WorkoutSet]) -> String {
        guard !sets.isEmpty,
              let data = try? JSONEncoder().encode(sets),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func decodePlannedSets(from json: String) -> [WorkoutSet] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let sets = try? JSONDecoder().decode([WorkoutSet].self, from: data) else { return [] }
        return sets
    }
}

extension WorkoutSetRecord {
    var asSet: WorkoutSet {
        WorkoutSet(id: id, reps: reps, weight: weight, rpe: rpe)
    }

    convenience init(from set: WorkoutSet) {
        self.init(id: set.id, reps: set.reps, weight: set.weight, rpe: set.rpe)
    }
}

extension FoodRecord {
    var asEntry: FoodEntry {
        FoodEntry(
            id: id,
            name: name,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            meal: meal,
            date: date,
            servingLabel: servingLabel
        )
    }

    convenience init(from entry: FoodEntry) {
        self.init(
            id: entry.id,
            name: entry.name,
            calories: entry.calories,
            protein: entry.protein,
            carbs: entry.carbs,
            fat: entry.fat,
            meal: entry.meal,
            date: entry.date,
            servingLabel: entry.servingLabel
        )
    }
}

extension WeightRecord {
    var asEntry: WeightEntry {
        WeightEntry(id: id, weight: weight, date: date)
    }

    convenience init(from entry: WeightEntry) {
        self.init(id: entry.id, weight: entry.weight, date: entry.date)
    }
}

extension ProgressPhotoRecord {
    var asEntry: ProgressPhotoEntry {
        ProgressPhotoEntry(id: id, date: date, fileName: fileName, userId: userId)
    }

    convenience init(from entry: ProgressPhotoEntry) {
        self.init(id: entry.id, date: entry.date, fileName: entry.fileName, userId: entry.userId)
    }
}

extension CoachRecord {
    var asProfile: CoachProfile {
        CoachProfile(
            id: id,
            name: name,
            specialty: specialty,
            pricePerMonth: pricePerMonth,
            isOnline: isOnline,
            rating: rating,
            bio: bio,
            clientCount: clientCount,
            reviewCount: reviewCount,
            isVerified: isVerified,
            availability: CoachAvailability(rawValue: availabilityRaw) ?? (isOnline ? .online : .inPerson),
            location: location,
            specialties: Self.decodeJSON([String].self, from: specialtiesJSON) ?? [specialty],
            reviews: Self.decodeJSON([CoachReview].self, from: reviewsJSON) ?? [],
            photoFileName: photoFileName,
            transformationPhotoFileNames: Self.decodeJSON([String].self, from: transformationPhotosJSON) ?? [],
            isLive: isLive
        )
    }

    convenience init(from profile: CoachProfile) {
        self.init(
            id: profile.id,
            name: profile.name,
            specialty: profile.specialty,
            pricePerMonth: profile.pricePerMonth,
            isOnline: profile.isOnline,
            rating: profile.rating,
            bio: profile.bio,
            clientCount: profile.clientCount,
            reviewCount: profile.reviewCount,
            isVerified: profile.isVerified,
            availability: profile.availability,
            location: profile.location,
            specialties: profile.specialties,
            reviews: profile.reviews,
            photoFileName: profile.photoFileName,
            transformationPhotoFileNames: profile.transformationPhotoFileNames,
            isLive: profile.isLive
        )
    }
}

extension MealComponentRecord {
    var asComponent: MealComponent {
        MealComponent(
            id: id,
            name: name,
            amount: amount,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat
        )
    }

    convenience init(from component: MealComponent) {
        self.init(
            id: component.id,
            name: component.name,
            amount: component.amount,
            calories: component.calories,
            protein: component.protein,
            carbs: component.carbs,
            fat: component.fat
        )
    }
}

extension SavedMealRecord {
    var asSavedMeal: SavedMeal {
        SavedMeal(id: id, name: name, components: components.map(\.asComponent))
    }

    convenience init(from meal: SavedMeal) {
        let componentRecords = meal.components.map { MealComponentRecord(from: $0) }
        self.init(id: meal.id, name: meal.name, components: componentRecords)
    }
}

extension RoutineExerciseRecord {
    var asItem: RoutineExerciseItem {
        if plannedSetCount > 0 {
            return RoutineExerciseItem(
                id: id,
                exercise: Exercise(name: exerciseName, muscleGroup: muscleGroup),
                sortOrder: sortOrder,
                plannedSetCount: plannedSetCount,
                plannedReps: plannedReps,
                plannedWeight: plannedWeight
            )
        }
        if let legacySets = Self.decodePlannedSets(from: plannedSetsJSON), !legacySets.isEmpty {
            let first = legacySets[0]
            return RoutineExerciseItem(
                id: id,
                exercise: Exercise(name: exerciseName, muscleGroup: muscleGroup),
                sortOrder: sortOrder,
                plannedSetCount: legacySets.count,
                plannedReps: first.reps,
                plannedWeight: first.weight > 0 ? first.weight : 0
            )
        }
        return RoutineExerciseItem(
            id: id,
            exercise: Exercise(name: exerciseName, muscleGroup: muscleGroup),
            sortOrder: sortOrder
        )
    }

    convenience init(from item: RoutineExerciseItem, routineID: UUID) {
        self.init(
            id: item.id,
            routineID: routineID,
            exerciseName: item.exercise.name,
            muscleGroup: item.exercise.muscleGroup,
            sortOrder: item.sortOrder,
            plannedSetCount: item.plannedSetCount,
            plannedReps: item.plannedReps,
            plannedWeight: item.plannedWeight,
            plannedSetsJSON: Self.encodePlannedSets(item.resolvedPlannedSets)
        )
    }

    static func encodePlannedSets(_ sets: [WorkoutSet]) -> String {
        guard !sets.isEmpty,
              let data = try? JSONEncoder().encode(sets),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func decodePlannedSets(from json: String) -> [WorkoutSet]? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let sets = try? JSONDecoder().decode([WorkoutSet].self, from: data) else { return nil }
        return sets
    }
}

extension WorkoutRoutineRecord {
    var asRoutine: WorkoutRoutine {
        let owned = exercises
            .filter { $0.routineID == id }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.asItem)
        return WorkoutRoutine(id: id, name: name, exercises: owned)
    }

    convenience init(from routine: WorkoutRoutine) {
        let exerciseRecords = routine.exercises.map {
            RoutineExerciseRecord(from: $0, routineID: routine.id)
        }
        self.init(id: routine.id, name: routine.name, exercises: exerciseRecords)
    }
}

enum SyncFitModelContainer {
    static let schema = Schema([
        ExerciseRecord.self,
        WorkoutRecord.self,
        WorkoutSetRecord.self,
        FoodRecord.self,
        WeightRecord.self,
        ProgressPhotoRecord.self,
        CoachRecord.self,
        SavedMealRecord.self,
        MealComponentRecord.self,
        WorkoutRoutineRecord.self,
        RoutineExerciseRecord.self,
        AppSettings.self
    ])

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
