import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case dark = "Dark"
    case light = "Light"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func resolved(from raw: String) -> AppAppearance {
        if raw == "System" { return .dark }
        return AppAppearance(rawValue: raw) ?? .dark
    }
}

enum NutritionMacroDisplayStyle: String, CaseIterable, Identifiable, Codable {
    case rings = "Rings"
    case bars = "Bars"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .rings:
            return "Circular progress for calories and macros"
        case .bars:
            return "Horizontal progress bars for each macro"
        }
    }
}

enum ActivityLevel: String, CaseIterable, Identifiable, Codable {
    case sedentary = "Sedentary"
    case lightlyActive = "Lightly Active"
    case moderatelyActive = "Moderately Active"
    case veryActive = "Very Active"
    case extraActive = "Extra Active"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .sedentary: return "Desk job, little or no exercise"
        case .lightlyActive: return "Light exercise 1–3 days per week"
        case .moderatelyActive: return "Moderate exercise 3–5 days per week"
        case .veryActive: return "Hard exercise 6–7 days per week"
        case .extraActive: return "Very hard exercise or physical job"
        }
    }

    var multiplier: Double {
        switch self {
        case .sedentary: return 1.2
        case .lightlyActive: return 1.375
        case .moderatelyActive: return 1.55
        case .veryActive: return 1.725
        case .extraActive: return 1.9
        }
    }
}

enum FitnessGoal: String, CaseIterable, Identifiable, Codable {
    case buildMuscle = "Build Muscle"
    case loseFat = "Lose Fat"
    case gainStrength = "Gain Strength"
    case healthyLifestyle = "Healthy Lifestyle"

    var id: String { rawValue }

    var usesCaloriePlanner: Bool {
        self == .loseFat || self == .buildMuscle
    }

    static func fromStored(_ raw: String) -> FitnessGoal {
        if let goal = FitnessGoal(rawValue: raw) { return goal }
        switch raw {
        case "Athletic Performance": return .gainStrength
        case "General Health": return .healthyLifestyle
        default: return .healthyLifestyle
        }
    }
}

enum Gender: String, CaseIterable, Identifiable, Codable {
    case male = "Male"
    case female = "Female"
    case other = "Other"
    case preferNotToSay = "Prefer not to say"

    var id: String { rawValue }
}

enum MeasurementSystem: String, CaseIterable, Identifiable, Codable {
    case imperial = "Imperial (ft, lb)"
    case metric = "Metric (cm, kg)"

    var id: String { rawValue }
}

enum ExperienceLevel: String, CaseIterable, Identifiable, Codable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"

    var id: String { rawValue }
}

struct UserProfile: Codable {
    var name: String = ""
    var goal: FitnessGoal = .healthyLifestyle
    var experienceLevel: ExperienceLevel = .beginner
    var hasCoach: Bool = false
    var gender: Gender = .preferNotToSay
    var birthday: Date = Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now
    var heightCm: Double = 175
    var bodyWeightKg: Double = 75
    var measurementSystem: MeasurementSystem = .imperial
    var activityLevel: ActivityLevel = .moderatelyActive
    var calorieTarget: Int = 2200
    var proteinTarget: Int = 150
    var carbTarget: Int = 220
    var fatTarget: Int = 70
    var photoFileName: String?
    var photoURL: String?

    var age: Int {
        max(Calendar.current.dateComponents([.year], from: birthday, to: .now).year ?? 0, 0)
    }

    var heightFeet: Int {
        Int(heightCm / 30.48)
    }

    var heightInches: Int {
        Int(round(heightCm / 2.54)) % 12
    }

    var bodyWeightLbs: Double {
        bodyWeightKg * 2.20462
    }

    mutating func setHeight(feet: Int, inches: Int) {
        let totalInches = feet * 12 + inches
        heightCm = Double(totalInches) * 2.54
    }

    mutating func setBodyWeight(lbs: Double) {
        bodyWeightKg = lbs / 2.20462
    }

    mutating func applyMacroTargets(calories: Int) {
        calorieTarget = calories
        let weightLbs = bodyWeightKg * 2.20462
        proteinTarget = Int((weightLbs * 1.0).rounded())
        let fatCalories = Int((Double(calories) * 0.27).rounded())
        fatTarget = max(Int((Double(fatCalories) / 9.0).rounded()), 35)
        let proteinCalories = proteinTarget * 4
        let remaining = max(0, calories - proteinCalories - fatTarget * 9)
        carbTarget = max(Int((Double(remaining) / 4.0).rounded()), 50)
    }
}

struct Exercise: Identifiable, Codable {
    let id: UUID
    var name: String
    var muscleGroup: String

    init(id: UUID = UUID(), name: String, muscleGroup: String) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
    }
}

enum ExerciseEquipment: String, Codable, CaseIterable {
    case barbell
    case dumbbell
    case machine
    case cable
    case bodyweight
}

extension Exercise {
    /// Drives icon color on the workout plan — derived from exercise name, not routine context.
    var primaryMuscleGroup: String {
        Self.resolvePrimaryMuscleGroup(name: name, catalogGroup: muscleGroup)
    }

    static func resolvePrimaryMuscleGroup(name: String, catalogGroup: String) -> String {
        let lower = name.lowercased()

        if lower.contains("tricep") || lower.contains("skull") || lower.contains("pushdown") {
            return "Triceps"
        }
        if lower.contains("curl") || lower.contains("hammer") {
            return "Biceps"
        }
        if lower.contains("bench") || lower.contains("fly")
            || lower.contains("push-up") || lower.contains("push up")
            || (lower.contains("press") && (lower.contains("incline") || lower.contains("dumbbell"))) {
            return "Chest"
        }
        if lower.contains("overhead") || lower.contains("lateral")
            || lower.contains("face pull") || lower.contains("shoulder") {
            return "Shoulders"
        }
        if lower.contains("squat") || lower.contains("leg press") || lower.contains("leg curl")
            || lower.contains("leg extension") || lower.contains("calf") || lower.contains("lunge")
            || lower.contains("romanian") {
            return "Legs"
        }
        if lower.contains("row") || lower.contains("pull-up") || lower.contains("pull up")
            || lower.contains("pulldown") || lower.contains("pull down")
            || (lower.contains("deadlift") && !lower.contains("romanian")) {
            return "Back"
        }
        if lower.contains("plank") || lower.contains("crunch") || lower.contains("ab ")
            || lower.contains("rollout") || lower.contains("hanging leg") {
            return "Core"
        }
        if lower.contains("treadmill") || lower.contains("bike") || lower.contains("rowing")
            || lower.contains("stair") {
            return "Cardio"
        }

        switch catalogGroup {
        case "Chest", "Shoulders", "Back", "Legs", "Core", "Cardio":
            return catalogGroup
        case "Arms":
            return "Biceps"
        default:
            return "Core"
        }
    }

    var equipment: ExerciseEquipment {
        Self.inferredEquipment(for: name)
    }

    var isBodyweight: Bool {
        equipment == .bodyweight
    }

    static func inferredEquipment(for name: String) -> ExerciseEquipment {
        let lowered = name.lowercased()
        if lowered.contains("push-up") || lowered.contains("push up")
            || lowered.contains("pull-up") || lowered.contains("pull up")
            || lowered.contains("chin-up") || lowered.contains("dip")
            || lowered == "plank" || lowered.contains("hanging leg raise") {
            return .bodyweight
        }
        if lowered.contains("dumbbell") { return .dumbbell }
        if lowered.contains("cable") || lowered.contains("pulldown") || lowered.contains("pushdown") {
            return .cable
        }
        if lowered.contains("machine") || lowered.contains("leg press") || lowered.contains("leg curl")
            || lowered.contains("leg extension") || lowered.contains("treadmill") || lowered.contains("bike")
            || lowered.contains("rowing") || lowered.contains("stair") {
            return .machine
        }
        return .barbell
    }
}

struct WorkoutSet: Identifiable, Codable {
    let id: UUID
    var reps: Int
    var weight: Double
    var rpe: Int?

    init(id: UUID = UUID(), reps: Int, weight: Double, rpe: Int? = nil) {
        self.id = id
        self.reps = reps
        self.weight = weight
        self.rpe = rpe
    }
}

struct WorkoutEntry: Identifiable, Codable {
    let id: UUID
    var exercise: Exercise
    var sets: [WorkoutSet]
    var plannedSets: [WorkoutSet]
    var date: Date
    var notes: String

    init(
        id: UUID = UUID(),
        exercise: Exercise,
        sets: [WorkoutSet],
        plannedSets: [WorkoutSet] = [],
        date: Date = .now,
        notes: String = ""
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.plannedSets = plannedSets
        self.date = date
        self.notes = notes
    }

    var displaySummary: String {
        if !sets.isEmpty { return Self.setDetailLine(for: sets) }
        if !plannedSets.isEmpty { return Self.setDetailLine(for: plannedSets) + " · planned" }
        return "Ready to log"
    }

    var setsSummary: String {
        Self.setDetailLine(for: sets)
    }

    var plannedSetsSummary: String {
        Self.setDetailLine(for: plannedSets)
    }

    /// Compact form for last-session lines: `3×8 @ 135 lbs` or `8×145, 8×140`.
    static func compactPerformance(from sets: [WorkoutSet]) -> String {
        guard !sets.isEmpty else { return "" }
        if let first = sets.first,
           sets.allSatisfy({ $0.reps == first.reps && $0.weight == first.weight }) {
            if first.weight > 0 {
                return "\(sets.count)×\(first.reps) @ \(SyncFitFormat.decimal(first.weight)) lbs"
            }
            return "\(sets.count)×\(first.reps) @ bodyweight"
        }
        return sets.map { compactSetLabel($0) }.joined(separator: ", ")
    }

    static func setDetailLine(for sets: [WorkoutSet]) -> String {
        guard !sets.isEmpty else { return "Ready to log" }

        let setWord = sets.count == 1 ? "set" : "sets"

        if sets.count == 1 {
            return formatSummary(for: sets[0], count: 1, setWord: setWord)
        }

        if let first = sets.first,
           sets.allSatisfy({ $0.reps == first.reps && $0.weight == first.weight }) {
            return formatSummary(for: first, count: sets.count, setWord: setWord)
        }

        let setDetails = sets.map { compactSetLabel($0) }.joined(separator: ", ")
        return "\(sets.count) \(setWord) · \(setDetails)"
    }

    private static func summary(for sets: [WorkoutSet]) -> String {
        setDetailLine(for: sets)
    }

    private static func formatSummary(for set: WorkoutSet, count: Int = 1, setWord: String) -> String {
        let prefix = count == 1 ? "1 set" : "\(count) \(setWord)"
        if set.weight > 0 {
            return "\(prefix) · \(set.reps) reps · \(SyncFitFormat.decimal(set.weight)) lbs"
        }
        return "\(prefix) · \(set.reps) reps · bodyweight"
    }

    private static func compactSetLabel(_ set: WorkoutSet) -> String {
        if set.weight > 0 {
            return "\(set.reps)×\(SyncFitFormat.decimal(set.weight))"
        }
        return "\(set.reps) reps · bodyweight"
    }
}

struct ExerciseHistoryEntry: Identifiable {
    let id = UUID()
    let date: Date
    let setsCount: Int
    let repsSummary: String
    let weightSummary: String
}

struct WorkoutPlanLastSessionInfo {
    let text: String
    let isReadyPrompt: Bool
}

struct FoodEntry: Identifiable, Codable {
    let id: UUID
    var name: String
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var meal: MealType
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
        self.meal = meal
        self.date = date
        self.servingLabel = servingLabel
    }

    var detailLine: String {
        "\(displayServingSize) · \(calories) cal · \(protein)g protein"
    }

    /// Serving text for meal rows — never omitted.
    var displayServingSize: String {
        let trimmed = servingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let inferred = Self.inferServingLabel(
            name: name,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat
        ) {
            return inferred
        }
        return "1 serving"
    }

    static func inferServingLabel(
        name: String,
        calories: Int,
        protein: Int,
        carbs: Int,
        fat: Int
    ) -> String? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return nil }

        let candidates = FoodLibrary.items.filter { item in
            let libraryName = item.name.lowercased()
            return libraryName == normalizedName
                || normalizedName.contains(libraryName)
                || libraryName.contains(normalizedName)
        }

        for item in candidates {
            if let label = item.matchingServingLabel(
                calories: calories,
                protein: protein,
                carbs: carbs,
                fat: fat
            ) {
                return label
            }
        }
        return nil
    }
}

enum MealType: String, CaseIterable, Identifiable, Codable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snack = "Snack"

    var id: String { rawValue }

    var sectionTitle: String {
        switch self {
        case .snack: return "Snacks"
        default: return rawValue
        }
    }

    static var mealSections: [MealType] {
        [.breakfast, .lunch, .dinner, .snack]
    }

    /// Default meal for the sticky Log food flow based on time of day.
    static func contextualDefault(for date: Date = .now, calendar: Calendar = .current) -> MealType {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<10: return .breakfast
        case 10..<14: return .lunch
        case 14..<18: return .dinner
        default: return .snack
        }
    }

    var collapseStorageKey: String {
        "nutrition.meal.expanded.\(rawValue.lowercased())"
    }
}

struct WeightEntry: Identifiable, Codable {
    let id: UUID
    var weight: Double
    var date: Date

    init(id: UUID = UUID(), weight: Double, date: Date = .now) {
        self.id = id
        self.weight = weight
        self.date = date
    }
}

struct ProgressPhotoEntry: Identifiable, Codable {
    let id: UUID
    var date: Date
    var fileName: String
    var userId: String
    /// Remote Firebase Storage download URL (nil for legacy local-only photos).
    var downloadURL: String?
    /// Storage object path, e.g. users/{uid}/progress_photos/{id}.jpg
    var storagePath: String?

    init(
        id: UUID = UUID(),
        date: Date = .now,
        fileName: String,
        userId: String = ProgressPhotoStorage.localUserId,
        downloadURL: String? = nil,
        storagePath: String? = nil
    ) {
        self.id = id
        self.date = date
        self.fileName = fileName
        self.userId = userId
        self.downloadURL = downloadURL
        self.storagePath = storagePath
    }

    var imageURL: URL {
        ProgressPhotoStorage.imageURL(fileName: fileName, userId: userId)
    }

    var hasRemoteImage: Bool {
        if let downloadURL, !downloadURL.isEmpty { return true }
        return false
    }
}

enum CoachAvailability: String, Codable, CaseIterable, Identifiable {
    case online = "Online"
    case inPerson = "In-person"
    case both = "Both"

    var id: String { rawValue }

    var supportsOnline: Bool {
        self == .online || self == .both
    }

    var supportsInPerson: Bool {
        self == .inPerson || self == .both
    }
}

struct CoachReview: Identifiable, Codable, Hashable {
    let id: UUID
    var clientName: String
    var text: String
    var rating: Double
    var date: Date

    init(
        id: UUID = UUID(),
        clientName: String,
        text: String,
        rating: Double,
        date: Date = .now
    ) {
        self.id = id
        self.clientName = clientName
        self.text = text
        self.rating = rating
        self.date = date
    }
}

struct CoachProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var specialty: String
    var pricePerMonth: Int
    var isOnline: Bool
    var rating: Double
    var bio: String
    var clientCount: Int
    var reviewCount: Int
    var isVerified: Bool
    var availability: CoachAvailability
    var location: String
    var specialties: [String]
    var reviews: [CoachReview]
    var photoFileName: String?
    var photoURL: String?
    var transformationPhotoFileNames: [String]
    var isLive: Bool
    var isListed: Bool
    var coachUserID: String?
    var stripeChargesEnabled: Bool

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
        availability: CoachAvailability? = nil,
        location: String = "",
        specialties: [String] = [],
        reviews: [CoachReview] = [],
        photoFileName: String? = nil,
        photoURL: String? = nil,
        transformationPhotoFileNames: [String] = [],
        isLive: Bool = true,
        isListed: Bool = true,
        coachUserID: String? = nil,
        stripeChargesEnabled: Bool = false
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
        self.availability = availability ?? (isOnline ? .online : .inPerson)
        self.location = location
        self.specialties = specialties.isEmpty ? [specialty] : specialties
        self.reviews = reviews
        self.photoFileName = photoFileName
        self.photoURL = photoURL
        self.transformationPhotoFileNames = transformationPhotoFileNames
        self.isLive = isLive
        self.isListed = isListed
        self.coachUserID = coachUserID
        self.stripeChargesEnabled = stripeChargesEnabled
    }

    var coachFirestoreID: String {
        coachUserID ?? id.uuidString
    }

    var marketplaceCardSubtitle: String {
        if clientCount > 0 {
            return "\(specialty) · \(clientCount) clients"
        }
        return specialty
    }

    var hireCheckoutURL: URL {
        let coachId = coachFirestoreID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? coachFirestoreID
        return URL(string: "https://joinsyncfit.com/hire?coach=\(coachId)")!
    }

    var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    var availabilityBadge: String {
        switch availability {
        case .online: return "Online"
        case .inPerson: return "In-person"
        case .both: return "Online · In-person"
        }
    }

    var stripeCheckoutURL: URL {
        URL(string: "https://syncfit.app/hire/\(id.uuidString)")!
    }
}

struct MealComponent: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var amount: String
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int

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

struct SavedMeal: Identifiable, Codable {
    let id: UUID
    var name: String
    var components: [MealComponent]

    init(id: UUID = UUID(), name: String, components: [MealComponent]) {
        self.id = id
        self.name = name
        self.components = components
    }

    var totalCalories: Int { components.reduce(0) { $0 + $1.calories } }
    var totalProtein: Int { components.reduce(0) { $0 + $1.protein } }
    var totalCarbs: Int { components.reduce(0) { $0 + $1.carbs } }
    var totalFat: Int { components.reduce(0) { $0 + $1.fat } }
}

struct RoutineExerciseItem: Identifiable, Codable {
    let id: UUID
    var exercise: Exercise
    var sortOrder: Int
    var plannedSetCount: Int
    var plannedReps: Int
    var plannedWeight: Double?

    init(
        id: UUID = UUID(),
        exercise: Exercise,
        sortOrder: Int,
        plannedSetCount: Int = 3,
        plannedReps: Int = 8,
        plannedWeight: Double? = nil
    ) {
        self.id = id
        self.exercise = exercise
        self.sortOrder = sortOrder
        self.plannedSetCount = max(plannedSetCount, 1)
        self.plannedReps = max(plannedReps, 1)
        self.plannedWeight = plannedWeight
    }

    /// Deep copy for editor state — prevents cross-routine mutation.
    func isolatedCopy() -> RoutineExerciseItem {
        RoutineExerciseItem(
            id: id,
            exercise: Exercise(id: exercise.id, name: exercise.name, muscleGroup: exercise.muscleGroup),
            sortOrder: sortOrder,
            plannedSetCount: plannedSetCount,
            plannedReps: plannedReps,
            plannedWeight: plannedWeight
        )
    }

    var resolvedPlannedSets: [WorkoutSet] {
        guard let weight = plannedWeight else { return [] }
        return (0..<plannedSetCount).map { _ in
            WorkoutSet(reps: plannedReps, weight: weight)
        }
    }

    var hasConfiguredTargets: Bool {
        plannedWeight != nil
    }

    var plannedSummary: String {
        guard hasConfiguredTargets, let weight = plannedWeight else {
            return "Tap to set targets"
        }
        let setWord = plannedSetCount == 1 ? "set" : "sets"
        if weight > 0 {
            return "\(plannedSetCount) \(setWord) · \(plannedReps) reps · \(SyncFitFormat.decimal(weight)) lbs"
        }
        return "\(plannedSetCount) \(setWord) · \(plannedReps) reps · bodyweight"
    }
}

struct WorkoutRoutine: Identifiable, Codable {
    let id: UUID
    var name: String
    var exercises: [RoutineExerciseItem]

    init(id: UUID = UUID(), name: String, exercises: [RoutineExerciseItem]) {
        self.id = id
        self.name = name
        self.exercises = exercises
    }

    var sortedExercises: [RoutineExerciseItem] {
        exercises.sorted { $0.sortOrder < $1.sortOrder }
    }

    var categoryMuscleGroups: Set<String>? {
        guard let kind = WorkoutScheduleKind.matchingDayRoutine(named: name),
              let groups = kind.filterMuscleGroups else { return nil }
        return Set(groups)
    }

    func showsMuscleGroup(for exercise: Exercise) -> Bool {
        guard let groups = categoryMuscleGroups else { return false }
        return !groups.contains(exercise.muscleGroup)
    }
}

enum WorkoutScheduleKind: String, Codable, CaseIterable, Identifiable {
    case unassigned
    case rest
    case push
    case pull
    case legs
    case upper
    case lower
    case arms
    case backChest
    case fullBody
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unassigned: return "Not Assigned"
        case .rest: return "Rest"
        case .push: return "Push"
        case .pull: return "Pull"
        case .legs: return "Legs"
        case .upper: return "Upper"
        case .lower: return "Lower"
        case .arms: return "Arms"
        case .backChest: return "Back & Chest"
        case .fullBody: return "Full Body"
        case .custom: return "Custom"
        }
    }

    static var primaryDaySplits: [WorkoutScheduleKind] {
        [.push, .pull, .legs]
    }

    static var extraDaySplits: [WorkoutScheduleKind] {
        [.upper, .lower, .arms, .backChest]
    }

    static var pickerOptions: [WorkoutScheduleKind] {
        [.unassigned, .push, .pull, .legs, .upper, .lower, .arms, .backChest, .fullBody, .custom, .rest]
    }

    var matchKeywords: [String] {
        switch self {
        case .unassigned, .rest, .custom: return []
        case .push: return ["push"]
        case .pull: return ["pull"]
        case .legs: return ["legs", "leg day"]
        case .upper: return ["upper"]
        case .lower: return ["lower"]
        case .arms: return ["arms", "arm"]
        case .backChest: return ["back", "chest", "back & chest", "back and chest"]
        case .fullBody: return ["full body", "full"]
        }
    }

    static func matchingDayRoutine(named name: String) -> WorkoutScheduleKind? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for kind in primaryDaySplits + extraDaySplits {
            let preferred = "\(kind.displayName) Day"
            if trimmed.caseInsensitiveCompare(preferred) == .orderedSame {
                return kind
            }
        }
        return nil
    }

    /// Muscle groups included when browsing exercises for this split in the add-exercise sheet.
    var filterMuscleGroups: [String]? {
        switch self {
        case .unassigned, .rest, .custom: return nil
        case .push: return ["Chest", "Shoulders", "Arms"]
        case .pull: return ["Back", "Arms"]
        case .legs: return ["Legs"]
        case .upper: return ["Chest", "Back", "Shoulders", "Arms"]
        case .lower: return ["Legs"]
        case .arms: return ["Arms"]
        case .backChest: return ["Back", "Chest"]
        case .fullBody: return ExerciseLibrary.muscleGroups.filter { $0 != "Cardio" }
        }
    }
}

struct WorkoutScheduleAssignment: Codable, Equatable {
    var kind: WorkoutScheduleKind
    var customRoutineID: UUID?

    static let rest = WorkoutScheduleAssignment(kind: .rest)
    static let unassigned = WorkoutScheduleAssignment(kind: .unassigned)

    init(kind: WorkoutScheduleKind, customRoutineID: UUID? = nil) {
        self.kind = kind
        self.customRoutineID = customRoutineID
    }

    func displayTitle(matching routines: [WorkoutRoutine]) -> String {
        switch kind {
        case .unassigned:
            return "—"
        case .rest:
            return "Rest"
        case .custom:
            if let id = customRoutineID,
               let routine = routines.first(where: { $0.id == id }) {
                return Self.shortRoutineName(routine.name)
            }
            return "Custom"
        default:
            return kind.displayName
        }
    }

    func subtitle(matching routines: [WorkoutRoutine]) -> String {
        switch kind {
        case .unassigned:
            return "Assign a split"
        case .rest:
            return "Rest Day"
        case .custom:
            if let id = customRoutineID,
               let routine = routines.first(where: { $0.id == id }) {
                return routine.name
            }
            return "Custom Workout"
        default:
            if let id = customRoutineID,
               let routine = routines.first(where: { $0.id == id }) {
                return Self.shortRoutineName(routine.name)
            }
            return "\(kind.displayName) Day"
        }
    }

    func tagTitle(matching routines: [WorkoutRoutine]) -> String? {
        switch kind {
        case .unassigned:
            return nil
        case .rest:
            return "Rest"
        default:
            if let id = customRoutineID,
               let routine = routines.first(where: { $0.id == id }) {
                return Self.shortRoutineName(routine.name)
            }
            return kind.displayName
        }
    }

    func resolvedScheduleKind(matching routines: [WorkoutRoutine]) -> WorkoutScheduleKind {
        if kind == .custom,
           let id = customRoutineID,
           let routine = routines.first(where: { $0.id == id }),
           let inferred = WorkoutScheduleKind.matchingDayRoutine(named: routine.name) {
            return inferred
        }
        return kind
    }

    static func shortRoutineName(_ name: String) -> String {
        for keyword in ["Push", "Pull", "Legs", "Upper", "Lower", "Full Body"] {
            if name.localizedCaseInsensitiveContains(keyword) {
                return keyword
            }
        }
        return name.replacingOccurrences(of: " Day", with: "", options: .caseInsensitive)
    }
}

struct WorkoutWeekSchedule: Codable, Equatable {
    /// Index 0 = Sunday … 6 = Saturday (`Calendar` weekday − 1).
    var days: [WorkoutScheduleAssignment]

    init(days: [WorkoutScheduleAssignment]) {
        self.days = days
    }

    static var blank: WorkoutWeekSchedule {
        WorkoutWeekSchedule(days: Array(repeating: .unassigned, count: 7))
    }

    /// Default for a new/empty account — blank days, never a canned split that can look like another user's plan.
    static var `default`: WorkoutWeekSchedule {
        .blank
    }

    func assignment(forWeekday weekday: Int) -> WorkoutScheduleAssignment {
        let index = max(0, min(6, weekday - 1))
        guard days.indices.contains(index) else { return .unassigned }
        return days[index]
    }

    mutating func setAssignment(_ assignment: WorkoutScheduleAssignment, forWeekday weekday: Int) {
        let index = max(0, min(6, weekday - 1))
        guard days.indices.contains(index) else { return }
        days[index] = assignment
    }

    static let mondayFirstDisplay: [(label: String, weekday: Int)] = [
        ("MON", 2), ("TUE", 3), ("WED", 4), ("THU", 5),
        ("FRI", 6), ("SAT", 7), ("SUN", 1)
    ]

    static func dayAbbreviation(forWeekday weekday: Int) -> String {
        mondayFirstDisplay.first { $0.weekday == weekday }?.label
            ?? WorkoutScheduleFormatters.weekdayName(
                for: Calendar.current.date(from: DateComponents(weekday: weekday)) ?? .now,
                short: true
            ).uppercased()
    }
}

struct WorkoutSchedulePreview {
    let todayTitle: String
    let nextTitle: String?
    let nextDayAbbrev: String?
    let nextWeekdayName: String?
}

enum WorkoutScheduleFormatters {
    static func weekdayName(for date: Date, short: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = short ? "EEE" : "EEEE"
        return formatter.string(from: date)
    }
}

struct WorkoutSetPosition {
    let exerciseName: String
    let currentSet: Int
    let totalSets: Int
    let exerciseIndex: Int
    let exerciseCount: Int
}

struct RecentWorkoutDaySummary: Identifiable {
    var id: Date { date }
    let date: Date
    let sessionName: String
    let durationMinutes: Int
    let totalSets: Int
    let personalRecords: Int
    let volumeDeltaVsPrevious: Int?
}

struct WorkoutFocusContext {
    let proteinCurrent: Int
    let proteinTarget: Int
    let caloriesCurrent: Int
    let calorieTarget: Int
    let isReadyToTrain: Bool
}

struct WorkoutPreflightInfo {
    let estimatedMinutes: Int
    let exerciseCount: Int
    let previousWorkoutLabel: String?
    let lastDurationMinutes: Int?
}

enum WorkoutSessionState {
    case notStarted
    case inProgress
    case completed
}

struct PersonalRecordDetail: Identifiable {
    let id = UUID()
    let exerciseName: String
    let detail: String
}

enum WorkoutEntryMarker {
    static let manual = "#manual"
}

struct DailyNutritionTotals: Equatable, Hashable {
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int

    static let empty = DailyNutritionTotals(calories: 0, protein: 0, carbs: 0, fat: 0)

    static func from(foods: [FoodEntry]) -> DailyNutritionTotals {
        DailyNutritionTotals(
            calories: foods.reduce(0) { $0 + $1.calories },
            protein: foods.reduce(0) { $0 + $1.protein },
            carbs: foods.reduce(0) { $0 + $1.carbs },
            fat: foods.reduce(0) { $0 + $1.fat }
        )
    }
}

struct SyncFitCoachCardModel {
    struct ProteinStat {
        let primaryText: String
        let label: String
        let deltaText: String?
        let goalHit: Bool
    }

    struct VolumeStat {
        let primaryText: String
        let label: String
        let deltaText: String
    }

    let protein: ProteinStat
    let volume: VolumeStat
}

struct WorkoutSessionResult: Identifiable {
    let id = UUID()
    let sessionName: String
    let durationMinutes: Int
    let totalVolumeLbs: Double
    let personalRecords: Int
    let proteinGoalMet: Bool
    let estimatedCaloriesBurned: Int
}

struct RoutineExerciseDraft: Identifiable {
    let id: UUID
    var exercise: Exercise
    var sets: [WorkoutSet]
    var notes: String

    init(
        id: UUID = UUID(),
        exercise: Exercise,
        sets: [WorkoutSet] = [WorkoutSet(reps: 8, weight: 135)],
        notes: String = ""
    ) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
        self.notes = notes
    }
}
