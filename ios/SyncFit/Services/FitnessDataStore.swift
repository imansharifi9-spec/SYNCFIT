import Foundation
import SwiftData
import UIKit

@MainActor
final class FitnessDataStore: ObservableObject {
    @Published private(set) var workouts: [WorkoutEntry] = []
    @Published private(set) var foods: [FoodEntry] = []
    /// Updates when the local calendar day changes so views refresh daily nutrition totals.
    @Published private(set) var currentCalendarDay: Date = Calendar.current.startOfDay(for: .now)
    @Published private(set) var weights: [WeightEntry] = []
    @Published private(set) var progressPhotos: [ProgressPhotoEntry] = []
    @Published private(set) var coaches: [CoachProfile] = []
    @Published private(set) var exercises: [Exercise] = []
    @Published private(set) var savedMeals: [SavedMeal] = []
    @Published private(set) var routines: [WorkoutRoutine] = []
    @Published private(set) var weekSchedule: WorkoutWeekSchedule = .default

    private var sessionLabelsByDay: [String: String] = [:]
    private var dayTemplateRoutineIDs: [String: UUID] = [:]
    private var activeDayTemplateKinds: [String: String] = [:]
    private var suppressDayTemplateAutoSeed = false
    private var completedWorkoutDays: Set<String> = []
    private static let sessionDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let context: ModelContext
    var healthKit: HealthKitService?
    var firestore: FirestoreDatabaseManager?
    var isHealthSyncEnabled: () -> Bool = { false }

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    var todaysFoods: [FoodEntry] {
        foods(on: .now)
    }

    var todaysNutritionTotals: DailyNutritionTotals {
        DailyNutritionTotals.from(foods: todaysFoods)
    }

    var todaysCalories: Int {
        todaysNutritionTotals.calories
    }

    var todaysProtein: Int {
        todaysNutritionTotals.protein
    }

    func totalProteinToday() -> Int {
        refreshCurrentCalendarDayIfNeeded()
        return todaysNutritionTotals.protein
    }

    func totalCaloriesToday() -> Int {
        refreshCurrentCalendarDayIfNeeded()
        return todaysNutritionTotals.calories
    }

    var todaysCarbs: Int {
        todaysNutritionTotals.carbs
    }

    var todaysFat: Int {
        todaysNutritionTotals.fat
    }

    var hasWorkoutToday: Bool {
        !workouts(on: .now).isEmpty
    }

    /// Weight delta in pounds (positive = gained). Nil when there isn't enough data.
    func weeklyWeightDelta(calendar: Calendar = .current) -> Double? {
        guard weights.count >= 2 else { return nil }

        let latest = weights[0]
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start
            ?? calendar.startOfDay(for: .now)

        if let baseline = weights.first(where: { $0.date < weekStart }) {
            return latest.weight - baseline.weight
        }

        let thisWeek = weights.filter { $0.date >= weekStart }
        guard let earliest = thisWeek.last, earliest.id != latest.id else { return nil }
        return latest.weight - earliest.weight
    }

    var todaysWorkouts: [WorkoutEntry] {
        workouts(on: .now)
    }

    func todayWorkoutSessionName() -> String? {
        sessionName(for: .now)
    }

    func sessionLabel(for date: Date) -> String? {
        sessionLabelsByDay[Self.dayKey(for: date)]
    }

    func setSessionLabel(_ label: String?, for date: Date) {
        let key = Self.dayKey(for: date)
        if let label, !label.isEmpty {
            sessionLabelsByDay[key] = label
        } else {
            sessionLabelsByDay.removeValue(forKey: key)
        }
        persistSessionLabels()
        objectWillChange.send()
    }

    func displaySessionName(for date: Date) -> String? {
        sessionLabel(for: date)
    }

    func sessionName(for date: Date) -> String? {
        sessionLabel(for: date)
    }

    func assignedTemplateRoutine(for kind: WorkoutScheduleKind) -> WorkoutRoutine? {
        guard let id = dayTemplateRoutineIDs[kind.rawValue] else { return nil }
        return routines.first(where: { $0.id == id })
    }

    func allSplittableKinds() -> [WorkoutScheduleKind] {
        WorkoutScheduleKind.primaryDaySplits + WorkoutScheduleKind.extraDaySplits
    }

    func assignTemplateRoutine(_ routine: WorkoutRoutine?, to kind: WorkoutScheduleKind) {
        if let routine {
            dayTemplateRoutineIDs[kind.rawValue] = routine.id
        } else {
            dayTemplateRoutineIDs.removeValue(forKey: kind.rawValue)
        }
        persistDayTemplateAssignments()
        objectWillChange.send()
    }

    func activeDayTemplate(for date: Date) -> WorkoutScheduleKind? {
        guard let raw = activeDayTemplateKinds[Self.dayKey(for: date)] else { return nil }
        return WorkoutScheduleKind(rawValue: raw)
    }

    func clearDayTemplate(for date: Date) {
        let key = Self.dayKey(for: date)
        guard let raw = activeDayTemplateKinds.removeValue(forKey: key),
              let previousKind = WorkoutScheduleKind(rawValue: raw),
              let routine = assignedTemplateRoutine(for: previousKind) else {
            persistActiveDayTemplateKinds()
            objectWillChange.send()
            return
        }

        removeTemplateExercises(from: routine, on: date)
        persistActiveDayTemplateKinds()
        objectWillChange.send()
    }

    func expectedSplitKind(for date: Date) -> WorkoutScheduleKind? {
        let assignment = scheduledAssignment(for: date)
        switch assignment.kind {
        case .unassigned, .rest:
            return nil
        case .custom:
            if let id = assignment.customRoutineID,
               let routine = routines.first(where: { $0.id == id }),
               let kind = WorkoutScheduleKind.matchingDayRoutine(named: routine.name) {
                return kind
            }
            return nil
        default:
            return assignment.kind
        }
    }

    /// Single source of truth for which routine is scheduled on a calendar day.
    func routine(for date: Date) -> WorkoutRoutine? {
        scheduledRoutine(for: date)
    }


    /// True when at least one workout entry on this day has completed/logged sets.
    func hasLoggedWorkoutHistory(on date: Date, calendar: Calendar = .current) -> Bool {
        workouts(on: date, calendar: calendar).contains { !$0.sets.isEmpty }
    }

    /// Shared day title for Home + Workouts: frozen session label when the day was trained,
    /// otherwise the current schedule/routine display name.
    func workoutDayDisplayTitle(for date: Date) -> String {
        if hasLoggedWorkoutHistory(on: date),
           let label = sessionLabel(for: date),
           !label.isEmpty {
            return label
        }
        return routineDisplayName(for: date)
    }

    func routineDisplayName(for date: Date) -> String {
        if let routine = routine(for: date) {
            return routine.name
        }
        let assignment = scheduledAssignment(for: date)
        switch assignment.kind {
        case .unassigned:
            return "No workout scheduled"
        case .rest:
            return "Rest Day"
        default:
            let title = assignment.displayTitle(matching: routines)
            return title == "—" ? "No workout scheduled" : title
        }
    }

    /// True when today has a concrete scheduled routine (or logged plan), not just an empty placeholder day.
    func hasScheduledWorkout(for date: Date = .now) -> Bool {
        if isRestDay(for: date) { return false }
        if routine(for: date) != nil { return true }
        if plannedExerciseCount(for: date) > 0 { return true }
        if !workouts(on: date).isEmpty { return true }
        return false
    }

    /// Current body weight for Home/Progress tiles: latest logged entry, else profile.
    func currentBodyWeightLbs(profile: UserProfile) -> Double {
        if let latest = weights.first {
            return latest.weight
        }
        return profile.bodyWeightLbs
    }

    func routineExerciseCount(for date: Date) -> Int {
        routine(for: date)?.sortedExercises.count ?? 0
    }

    /// Reconcile a day's logged plan with the weekly schedule assignment.
    func syncWorkoutDayFromSchedule(for date: Date) {
        let assignment = scheduledAssignment(for: date)
        let dayKey = Self.dayKey(for: date)

        if let active = activeDayTemplate(for: date) {
            let scheduledKind = assignment.resolvedScheduleKind(matching: routines)
            if assignment.kind == .rest
                || assignment.kind == .unassigned
                || active != scheduledKind {
                activeDayTemplateKinds.removeValue(forKey: dayKey)
                persistActiveDayTemplateKinds()
            }
        }

        switch assignment.kind {
        case .unassigned:
            break
        case .rest:
            if workoutSessionState(for: date) == .notStarted {
                clearDayTemplate(for: date)
            }
        default:
            if shouldRefreshDayPlan(for: date) {
                applyScheduledPlan(for: date)
            }
        }

        objectWillChange.send()
    }

    private func shouldRefreshDayPlan(for date: Date) -> Bool {
        let state = workoutSessionState(for: date)
        if state == .inProgress || state == .completed {
            return false
        }

        guard let routine = scheduledRoutine(for: date) else { return false }

        let plannedNames = Set(
            routine.sortedExercises.map { $0.exercise.name.lowercased() }
        )
        let currentNames = Set(
            workouts(on: date)
                .filter { !isManualWorkoutEntry($0) }
                .map { $0.exercise.name.lowercased() }
        )
        return plannedNames != currentNames
    }

    func scheduledTitle(for date: Date) -> String? {
        let assignment = scheduledAssignment(for: date)
        switch assignment.kind {
        case .unassigned:
            return nil
        case .rest:
            return "Rest Day"
        default:
            if let routine = scheduledRoutine(for: date) {
                return routine.name
            }
            if assignment.kind != .custom {
                return "\(assignment.kind.displayName) Day"
            }
            return assignment.kind.displayName
        }
    }

    func assignRoutine(_ routine: WorkoutRoutine, toWeekday weekday: Int) {
        let matchedKind = WorkoutScheduleKind.matchingDayRoutine(named: routine.name) ?? .custom
        let assignment = WorkoutScheduleAssignment(kind: matchedKind, customRoutineID: routine.id)
        print("[WorkoutSync] PART1 schedule slot weekday=\(weekday) kind=\(matchedKind.rawValue) customRoutineID=\(routine.id.uuidString) name=\(routine.name) exercises=\(routine.exercises.count)")
        if matchedKind != .custom {
            assignTemplateRoutine(routine, to: matchedKind)
        }
        setScheduleAssignment(assignment, forWeekday: weekday)

        // Ensure the routine document the schedule points at exists in Firestore.
        // Without this, PART1 (slot) can succeed while PART2 (content) is missing.
        syncToFirestoreIfNeeded(label: "saveRoutine.assignSlot") { try await $0.saveRoutine(routine) }

        let targetDate = dateForWeekday(weekday)
        applyRoutineToDay(routine, on: targetDate)
        objectWillChange.send()
    }

    func assignRest(toWeekday weekday: Int) {
        setScheduleAssignment(.rest, forWeekday: weekday)
        let targetDate = dateForWeekday(weekday)
        clearDayTemplate(for: targetDate)
        objectWillChange.send()
    }

    func isRestAssigned(toWeekday weekday: Int) -> Bool {
        weekSchedule.assignment(forWeekday: weekday).kind == .rest
    }

    func isRoutineAssigned(_ routine: WorkoutRoutine, toWeekday weekday: Int) -> Bool {
        let assignment = weekSchedule.assignment(forWeekday: weekday)
        guard assignment.kind != .rest, assignment.kind != .unassigned else { return false }
        if assignment.customRoutineID == routine.id { return true }
        return resolveRoutine(for: assignment)?.id == routine.id
    }

    func assignmentCount(for routine: WorkoutRoutine) -> Int {
        weekSchedule.days.filter { assignment in
            guard assignment.kind != .rest, assignment.kind != .unassigned else { return false }
            if assignment.customRoutineID == routine.id { return true }
            return resolveRoutine(for: assignment)?.id == routine.id
        }.count
    }

    func applyScheduledPlan(for date: Date) {
        let assignment = scheduledAssignment(for: date)
        guard assignment.kind != .unassigned, assignment.kind != .rest else { return }
        if let routine = scheduledRoutine(for: date) {
            applyRoutineToDay(routine, on: date)
        } else if let kind = expectedSplitKind(for: date) {
            _ = prepareAndApplyDayTemplate(kind, on: date)
        }
    }

    func expectedMuscleGroups(for date: Date) -> [String]? {
        expectedSplitKind(for: date)?.filterMuscleGroups
    }

    func isOffCategoryExercise(_ entry: WorkoutEntry, on date: Date) -> Bool {
        guard let groups = expectedMuscleGroups(for: date), !groups.isEmpty else { return false }
        return !groups.contains(entry.exercise.muscleGroup)
    }

    func isManualWorkoutEntry(_ entry: WorkoutEntry) -> Bool {
        entry.notes.contains(WorkoutEntryMarker.manual)
    }

    func workoutSessionState(for date: Date) -> WorkoutSessionState {
        let key = Self.dayKey(for: date)
        if completedWorkoutDays.contains(key) {
            return .completed
        }
        let hasLoggedSets = workouts(on: date).contains { !$0.sets.isEmpty }
        return hasLoggedSets ? .inProgress : .notStarted
    }

    func markWorkoutCompleted(for date: Date) {
        completedWorkoutDays.insert(Self.dayKey(for: date))
        persistCompletedWorkoutDays()
        objectWillChange.send()
    }

    func markWorkoutInProgress(for date: Date) {
        let key = Self.dayKey(for: date)
        guard completedWorkoutDays.contains(key) else { return }
        completedWorkoutDays.remove(key)
        persistCompletedWorkoutDays()
        objectWillChange.send()
    }

    func personalRecordDetails(on date: Date, calendar: Calendar = .current) -> [PersonalRecordDetail] {
        let dayStart = calendar.startOfDay(for: date)
        return workouts(on: date, calendar: calendar).compactMap { entry in
            guard !entry.sets.isEmpty else { return nil }

            let sessionMaxWeight = entry.sets.map(\.weight).max() ?? 0
            let sessionMaxReps = entry.sets.map(\.reps).max() ?? 0
            let historicalWeight = workouts
                .filter { !calendar.isDate($0.date, inSameDayAs: dayStart) }
                .filter { $0.exercise.name.caseInsensitiveCompare(entry.exercise.name) == .orderedSame }
                .flatMap(\.sets)
                .map(\.weight)
                .max() ?? 0
            let historicalReps = workouts
                .filter { !calendar.isDate($0.date, inSameDayAs: dayStart) }
                .filter { $0.exercise.name.caseInsensitiveCompare(entry.exercise.name) == .orderedSame }
                .flatMap(\.sets)
                .map(\.reps)
                .max() ?? 0

            if sessionMaxWeight > historicalWeight, sessionMaxWeight > 0 {
                return PersonalRecordDetail(
                    exerciseName: entry.exercise.name,
                    detail: "new max: \(SyncFitFormat.decimal(sessionMaxWeight)) lbs"
                )
            }
            if sessionMaxWeight == 0, sessionMaxReps > historicalReps {
                return PersonalRecordDetail(
                    exerciseName: entry.exercise.name,
                    detail: "new rep PR: \(sessionMaxReps) reps"
                )
            }
            return nil
        }
    }

    func buildSessionResult(for date: Date, profile: UserProfile) -> WorkoutSessionResult {
        let name = displaySessionName(for: date) ?? expectedSplitKind(for: date)?.displayName ?? "Workout"
        return WorkoutSessionResult(
            sessionName: name,
            durationMinutes: estimatedWorkoutMinutes(on: date),
            totalVolumeLbs: totalVolume(on: date),
            personalRecords: personalRecordsCount(on: date),
            proteinGoalMet: proteinGoalMet(on: date, target: profile.proteinTarget),
            estimatedCaloriesBurned: max(estimatedWorkoutMinutes(on: date) * 8, 120)
        )
    }

    func formattedVolume(_ lbs: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: Int(lbs.rounded()))) ?? "\(Int(lbs.rounded()))"
    }

    func proteinLogged(on date: Date, calendar: Calendar = .current) -> Int {
        foods(on: date, calendar: calendar).reduce(0) { $0 + $1.protein }
    }

    func proteinRemainingToday(profile: UserProfile, calendar: Calendar = .current) -> Int {
        max(0, profile.proteinTarget - todaysNutritionTotals.protein)
    }

    func recommendedProteinPerRemainingMeal(profile: UserProfile, calendar: Calendar = .current) -> Int {
        let remaining = proteinRemainingToday(profile: profile, calendar: calendar)
        guard remaining > 0 else { return 0 }
        let mealsLeft = max(1, estimatedMealsRemainingToday(calendar: calendar))
        return max(10, min(60, remaining / mealsLeft))
    }

    private func estimatedMealsRemainingToday(calendar: Calendar = .current) -> Int {
        let hour = calendar.component(.hour, from: .now)
        switch hour {
        case 0..<10: return 4
        case 10..<14: return 3
        case 14..<18: return 2
        case 18..<22: return 1
        default: return 1
        }
    }

    /// Call when the app becomes active or a nutrition screen appears so day-bound totals roll forward.
    func refreshCurrentCalendarDayIfNeeded(calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: .now)
        guard currentCalendarDay != today else { return }
        currentCalendarDay = today
    }

    func plannedVolume(on date: Date, calendar: Calendar = .current) -> Double {
        workouts(on: date, calendar: calendar).reduce(0) { total, entry in
            let volume = entry.plannedSets.reduce(0.0) { $0 + ($1.weight * Double($1.reps)) }
            return total + volume
        }
    }

    func routineTypeLabel(for date: Date) -> String? {
        if let label = sessionLabel(for: date), !label.isEmpty {
            return label
        }
        if let routine = routine(for: date) {
            return routine.name
        }
        let assignment = scheduledAssignment(for: date)
        switch assignment.kind {
        case .unassigned, .rest:
            return nil
        default:
            let title = assignment.displayTitle(matching: routines)
            return title == "—" ? nil : title
        }
    }

    func coachCardModel(for date: Date, profile: UserProfile) -> SyncFitCoachCardModel {
        let sessionState = workoutSessionState(for: date)
        let proteinTarget = profile.proteinTarget
        let proteinLoggedToday = todaysNutritionTotals.protein
        let proteinStat: SyncFitCoachCardModel.ProteinStat

        if proteinTarget <= 0 {
            proteinStat = SyncFitCoachCardModel.ProteinStat(
                primaryText: "—g",
                label: "set up nutrition to track",
                deltaText: nil,
                goalHit: false
            )
        } else if proteinLoggedToday >= proteinTarget {
            proteinStat = SyncFitCoachCardModel.ProteinStat(
                primaryText: "Goal hit 🎯",
                label: "protein goal",
                deltaText: nil,
                goalHit: true
            )
        } else {
            let remaining = proteinRemainingToday(profile: profile)
            let mealTarget = recommendedProteinPerRemainingMeal(profile: profile)
            proteinStat = SyncFitCoachCardModel.ProteinStat(
                primaryText: "\(remaining)g",
                label: "protein remaining",
                deltaText: "↑ aim for \(mealTarget)g next meal",
                goalHit: false
            )
        }

        let loggedVolume = totalVolume(on: date)
        let planned = plannedVolume(on: date)
        let isScheduledRest = isRestDay(for: date)
            && workouts(on: date).isEmpty
            && activeDayTemplate(for: date) == nil

        let volumeStat: SyncFitCoachCardModel.VolumeStat
        if isScheduledRest {
            volumeStat = restDayVolumeStat(relativeTo: date)
        } else {
            let displayVolume: Double
            let volumeLabel: String

            switch sessionState {
            case .notStarted:
                displayVolume = planned
                volumeLabel = "planned volume"
            case .inProgress, .completed:
                displayVolume = loggedVolume > 0 ? loggedVolume : planned
                volumeLabel = "lbs volume today"
            }

            volumeStat = SyncFitCoachCardModel.VolumeStat(
                primaryText: formattedVolume(displayVolume),
                label: volumeLabel,
                deltaText: volumeDeltaDescription(for: date, currentVolume: displayVolume)
            )
        }

        return SyncFitCoachCardModel(protein: proteinStat, volume: volumeStat)
    }

    private func restDayVolumeStat(relativeTo date: Date) -> SyncFitCoachCardModel.VolumeStat {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: dayStart),
           !workouts(on: yesterday).isEmpty {
            let volume = totalVolume(on: yesterday)
            return SyncFitCoachCardModel.VolumeStat(
                primaryText: formattedVolume(volume),
                label: "lbs volume yesterday",
                deltaText: volumeDeltaDescription(for: yesterday, currentVolume: volume)
            )
        }

        if let recent = mostRecentWorkoutDate(before: dayStart, calendar: calendar) {
            let volume = totalVolume(on: recent)
            return SyncFitCoachCardModel.VolumeStat(
                primaryText: formattedVolume(volume),
                label: "lbs last session",
                deltaText: volumeDeltaDescription(for: recent, currentVolume: volume)
            )
        }

        return SyncFitCoachCardModel.VolumeStat(
            primaryText: "0",
            label: "lbs volume yesterday",
            deltaText: "No recent session"
        )
    }

    private func mostRecentWorkoutDate(
        before date: Date,
        calendar: Calendar = .current,
        lookbackDays: Int = 14
    ) -> Date? {
        var searchDay = calendar.startOfDay(for: date)
        for _ in 0..<lookbackDays {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: searchDay) else { break }
            searchDay = previous
            if !workouts(on: previous).isEmpty {
                return previous
            }
        }
        return nil
    }

    func volumeDeltaDescription(for date: Date, currentVolume: Double) -> String {
        guard currentVolume > 0 else { return "First session" }
        guard let currentLabel = routineTypeLabel(for: date)?.lowercased(), !currentLabel.isEmpty else {
            return "First session"
        }

        let calendar = Calendar.current
        var searchDay = calendar.startOfDay(for: date)

        for _ in 0..<90 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: searchDay) else { break }
            searchDay = previous
            guard !workouts(on: previous).isEmpty else { continue }

            guard let previousLabel = routineTypeLabel(for: previous)?.lowercased(), !previousLabel.isEmpty else {
                continue
            }
            guard sessionsMatch(currentLabel, previousLabel) else { continue }

            let previousVolume = totalVolume(on: previous)
            guard previousVolume > 0 else { continue }

            let percent = Int(((currentVolume - previousVolume) / previousVolume * 100).rounded())
            let arrow = percent >= 0 ? "↑" : "↓"
            let sign = percent > 0 ? "+" : ""
            let shortLabel = shortSessionLabel(routineTypeLabel(for: previous) ?? previousLabel)
            return "\(arrow) \(sign)\(percent)% vs last \(shortLabel)"
        }

        return "First session"
    }

    private func sessionsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }

    private func shortSessionLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(" day") {
            return String(trimmed.dropLast(4))
        }
        return trimmed
    }

    func restTimerDurationSeconds() -> Int {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return 90 }
        return max(settings.restTimerSeconds, 15)
    }

    func setRestTimerDurationSeconds(_ seconds: Int) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.restTimerSeconds = max(seconds, 15)
        try? context.save()
    }

    func exerciseNote(for exerciseName: String) -> String {
        exerciseNotesMap()[exerciseName.lowercased()] ?? ""
    }

    func setExerciseNote(_ note: String, for exerciseName: String) {
        var map = exerciseNotesMap()
        let key = exerciseName.lowercased()
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = trimmed
        }
        persistExerciseNotesMap(map)
    }

    func lastPerformanceLine(for exerciseName: String, before date: Date) -> String? {
        guard let entry = lastWorkoutEntry(for: exerciseName, before: date), !entry.sets.isEmpty else {
            return nil
        }
        let perf = WorkoutEntry.compactPerformance(from: entry.sets)
        let relative = relativeWorkoutDate(entry.date, from: date)
        return "Last: \(perf) · \(relative)"
    }

    func workoutPlanLastSessionLine(for workout: WorkoutEntry, on date: Date) -> WorkoutPlanLastSessionInfo {
        if !workout.sets.isEmpty {
            let perf = WorkoutEntry.compactPerformance(from: workout.sets)
            let relative = relativeWorkoutDate(workout.date, from: date)
            return WorkoutPlanLastSessionInfo(
                text: "Last: \(perf) · \(relative)",
                isReadyPrompt: false
            )
        }
        if let prior = lastWorkoutEntry(for: workout.exercise.name, before: date), !prior.sets.isEmpty {
            let perf = WorkoutEntry.compactPerformance(from: prior.sets)
            let relative = relativeWorkoutDate(prior.date, from: date)
            return WorkoutPlanLastSessionInfo(
                text: "Last: \(perf) · \(relative)",
                isReadyPrompt: false
            )
        }
        return WorkoutPlanLastSessionInfo(text: "Ready to log", isReadyPrompt: true)
    }

    /// "Last session: 3×8 @ 135 lbs · 2 days ago" for active workout header.
    func lastSessionSummary(for exerciseName: String, before date: Date) -> (prefix: String, performance: String, suffix: String)? {
        guard let entry = lastWorkoutEntry(for: exerciseName, before: date), !entry.sets.isEmpty else {
            return nil
        }
        let setCount = entry.sets.count
        let reps: Int
        if let first = entry.sets.first, entry.sets.allSatisfy({ $0.reps == first.reps }) {
            reps = first.reps
        } else {
            reps = entry.sets.map(\.reps).max() ?? 0
        }
        let weight = entry.sets.map(\.weight).max() ?? 0
        let performance: String
        if weight > 0 {
            performance = "\(setCount)×\(reps) @ \(SyncFitFormat.decimal(weight)) lbs"
        } else {
            performance = "\(setCount)×\(reps) @ bodyweight"
        }
        let relative = relativeWorkoutDate(entry.date, from: date)
        return ("Last session: ", performance, " · \(relative)")
    }

    func exerciseHistory(for exerciseName: String, before date: Date, limit: Int = 5) -> [ExerciseHistoryEntry] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        var seenDays = Set<Date>()
        var results: [ExerciseHistoryEntry] = []

        for entry in workouts {
            guard entry.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame,
                  !entry.sets.isEmpty else { continue }
            let day = calendar.startOfDay(for: entry.date)
            guard day < dayStart, seenDays.insert(day).inserted else { continue }

            let repsSummary: String
            if let first = entry.sets.first,
               entry.sets.allSatisfy({ $0.reps == first.reps }) {
                repsSummary = "\(first.reps)"
            } else {
                repsSummary = entry.sets.map { "\($0.reps)" }.joined(separator: "/")
            }

            let maxWeight = entry.sets.map(\.weight).max() ?? 0
            let weightSummary = maxWeight > 0 ? "\(SyncFitFormat.decimal(maxWeight)) lb" : "BW"

            results.append(ExerciseHistoryEntry(
                date: day,
                setsCount: entry.sets.count,
                repsSummary: repsSummary,
                weightSummary: weightSummary
            ))
            if results.count >= limit { break }
        }
        return results
    }

    func relativeWorkoutDate(_ date: Date, from reference: Date = .now) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let ref = calendar.startOfDay(for: reference)
        let days = calendar.dateComponents([.day], from: start, to: ref).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let weeks = days / 7
        if weeks == 1 { return "1 week ago" }
        if weeks < 5 { return "\(weeks) weeks ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    func exerciseIndex(in routine: WorkoutRoutine, for exerciseName: String) -> Int? {
        routine.sortedExercises.firstIndex {
            $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame
        }
    }

    private func exerciseNotesMap() -> [String: String] {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first,
              !settings.exerciseNotesJSON.isEmpty,
              let data = settings.exerciseNotesJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func persistExerciseNotesMap(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.exerciseNotesJSON = json
        try? context.save()
    }

    func buildActiveWorkoutRoutine(for date: Date) -> WorkoutRoutine {
        let dayStart = Calendar.current.startOfDay(for: date)
        var items: [RoutineExerciseItem] = []
        var sortOrder = 0
        var seenNames = Set<String>()

        for entry in workouts(on: date) {
            let key = entry.exercise.name.lowercased()
            guard seenNames.insert(key).inserted else { continue }
            items.append(RoutineExerciseItem(exercise: entry.exercise, sortOrder: sortOrder))
            sortOrder += 1
        }

        if let kind = expectedSplitKind(for: date),
           let routine = assignedTemplateRoutine(for: kind) {
            let allowedGroups = kind.filterMuscleGroups ?? []
            for item in routine.sortedExercises {
                let key = item.exercise.name.lowercased()
                guard seenNames.insert(key).inserted else { continue }
                if !allowedGroups.isEmpty, !allowedGroups.contains(item.exercise.muscleGroup) {
                    continue
                }
                items.append(RoutineExerciseItem(exercise: item.exercise, sortOrder: sortOrder))
                sortOrder += 1
            }
        } else if let routine = scheduledRoutine(for: date) {
            for item in routine.sortedExercises {
                let key = item.exercise.name.lowercased()
                guard seenNames.insert(key).inserted else { continue }
                items.append(RoutineExerciseItem(exercise: item.exercise, sortOrder: sortOrder))
                sortOrder += 1
            }
        }

        let title = sessionLabel(for: date)
            ?? scheduledRoutine(for: date).map(\.name)
            ?? expectedSplitKind(for: date).map { "\($0.displayName) Day" }
            ?? "Workout"
        return WorkoutRoutine(name: title, exercises: items)
    }

    func prepareAndApplyDayTemplate(_ kind: WorkoutScheduleKind, on date: Date) -> Bool {
        linkDefaultRoutineIfAvailable(for: kind)
        guard assignedTemplateRoutine(for: kind) != nil else { return false }
        return applyDayTemplate(kind, on: date)
    }

    func applyRoutineToDay(_ routine: WorkoutRoutine, on date: Date) {
        if let kind = WorkoutScheduleKind.matchingDayRoutine(named: routine.name) {
            assignTemplateRoutine(routine, to: kind)
            applyDayTemplate(kind, on: date)
            return
        }

        syncDayPlanToRoutine(routine, on: date)
    }

    func resetWorkoutPlanning() {
        dayTemplateRoutineIDs.removeAll()
        activeDayTemplateKinds.removeAll()
        sessionLabelsByDay.removeAll()
        weekSchedule = .blank
        suppressDayTemplateAutoSeed = true
        persistDayTemplateAssignments()
        persistActiveDayTemplateKinds()
        persistSessionLabels()
        persistWeekSchedule(.blank)
        persistSuppressDayTemplateAutoSeed()
        objectWillChange.send()
    }

    private func linkDefaultRoutineIfAvailable(for kind: WorkoutScheduleKind) {
        guard dayTemplateRoutineIDs[kind.rawValue] == nil else { return }
        let preferredName = "\(kind.displayName) Day"
        guard let routine = routines.first(where: {
            $0.name.caseInsensitiveCompare(preferredName) == .orderedSame
        }) else { return }
        dayTemplateRoutineIDs[kind.rawValue] = routine.id
        persistDayTemplateAssignments()
    }

    @discardableResult
    func applyDayTemplate(_ kind: WorkoutScheduleKind, on date: Date) -> Bool {
        guard let routine = assignedTemplateRoutine(for: kind) else { return false }

        let dayKey = Self.dayKey(for: date)
        activeDayTemplateKinds[dayKey] = kind.rawValue
        persistActiveDayTemplateKinds()
        syncDayPlanToRoutine(routine, on: date, sessionLabel: kind.displayName)
        return true
    }

    func syncDayPlanToRoutine(
        _ routine: WorkoutRoutine,
        on date: Date,
        sessionLabel: String? = nil
    ) {
        let dayStart = Calendar.current.startOfDay(for: date)
        // PART2 content lives on the routine document (customRoutineID). Day workout
        // rows are a derived projection for the Workouts tab UI.
        print("[WorkoutSync] PART2 materialize day plan date=\(Self.dayKey(for: dayStart)) scheduleRoutineID=\(routine.id.uuidString) name=\(routine.name) exercises=\(routine.exercises.count)")
        if routine.exercises.isEmpty {
            print("[WorkoutSync] PART2 FAILED silently risk — routine \(routine.id.uuidString) has ZERO exercises; schedule slot will show Custom with empty day")
        }

        clearNonManualWorkouts(on: dayStart)

        let entries = routine.sortedExercises.map { item in
            WorkoutEntry(
                exercise: item.exercise,
                sets: [],
                plannedSets: item.resolvedPlannedSets,
                date: dayStart
            )
        }

        if !entries.isEmpty {
            for entry in entries {
                context.insert(WorkoutRecord(from: entry))
            }
            do {
                try context.save()
                workouts = fetchWorkouts()
                print("[WorkoutSync] PART2 local day rows saved date=\(Self.dayKey(for: dayStart)) count=\(entries.count) entryIDs=\(entries.map(\.id.uuidString).joined(separator: ","))")
            } catch {
                print("[WorkoutSync] PART2 local SwiftData save FAILED: \(error)")
            }
            // Also mirror planned day rows to Firestore workouts (logged/planned history).
            for entry in entries {
                syncToFirestoreIfNeeded(label: "saveWorkout.dayPlan") { try await $0.saveWorkout(entry) }
            }
        } else {
            print("[WorkoutSync] PART2 no day rows — routine content empty date=\(Self.dayKey(for: dayStart)) routineID=\(routine.id.uuidString)")
        }

        setSessionLabel(sessionLabel ?? routine.name, for: date)
        syncDayWorkoutIfNeeded(on: dayStart)
    }

    private func clearNonManualWorkouts(on date: Date? = nil) {
        let calendar = Calendar.current
        let toDelete = workouts.filter { entry in
            guard !isManualWorkoutEntry(entry) else { return false }
            guard let date else { return true }
            return calendar.isDate(entry.date, inSameDayAs: date)
        }
        guard !toDelete.isEmpty else { return }

        for entry in toDelete {
            let targetID = entry.id
            var descriptor = FetchDescriptor<WorkoutRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
            }
            syncToFirestoreIfNeeded(label: "deleteWorkout.clearDayPlan") {
                try await $0.deleteWorkout(entry)
            }
        }
        try? context.save()
        workouts = fetchWorkouts()
    }

    private func dateForWeekday(_ weekday: Int, reference: Date = .now) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let todayWeekday = calendar.component(.weekday, from: today)
        let delta = weekday - todayWeekday
        return calendar.date(byAdding: .day, value: delta, to: today) ?? today
    }

    private func removeTemplateExercises(from routine: WorkoutRoutine, on date: Date) {
        let templateNames = Set(routine.sortedExercises.map { $0.exercise.name.lowercased() })
        let entries = workouts(on: date).filter { templateNames.contains($0.exercise.name.lowercased()) }
        guard !entries.isEmpty else { return }

        for entry in entries {
            let targetID = entry.id
            var descriptor = FetchDescriptor<WorkoutRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
            }
        }
        saveAndReload()
    }

    func purgeOffCategoryExercises(on date: Date) {
        guard let groups = expectedMuscleGroups(for: date), !groups.isEmpty else { return }
        let offenders = workouts(on: date).filter { entry in
            !groups.contains(entry.exercise.muscleGroup) && !isManualWorkoutEntry(entry)
        }
        guard !offenders.isEmpty else { return }
        for entry in offenders {
            let targetID = entry.id
            var descriptor = FetchDescriptor<WorkoutRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            if let record = try? context.fetch(descriptor).first {
                context.delete(record)
            }
        }
        try? context.save()
        workouts = fetchWorkouts()
    }

    private func purgeOffCategoryExercisesForAllScheduledDays() {
        let calendar = Calendar.current
        let days = Set(workouts.map { calendar.startOfDay(for: $0.date) })
        for day in days {
            purgeOffCategoryExercises(on: day)
        }
    }

    private func loadCompletedWorkoutDays() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first,
              !settings.completedWorkoutDaysJSON.isEmpty,
              let data = settings.completedWorkoutDaysJSON.data(using: .utf8),
              let days = try? JSONDecoder().decode([String].self, from: data) else {
            completedWorkoutDays = []
            return
        }
        completedWorkoutDays = Set(days)
    }

    private func persistCompletedWorkoutDays() {
        guard let data = try? JSONEncoder().encode(Array(completedWorkoutDays)),
              let json = String(data: data, encoding: .utf8) else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.completedWorkoutDaysJSON = json
        try? context.save()
    }

    private static func dayKey(for date: Date) -> String {
        sessionDayFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    func hasWorkout(on date: Date, calendar: Calendar = .current) -> Bool {
        !workouts(on: date, calendar: calendar).isEmpty
    }

    func estimatedWorkoutMinutes(on date: Date) -> Int {
        let day = workouts(on: date)
        guard !day.isEmpty else { return 0 }

        let totalSets = day.reduce(0) { $0 + $1.sets.count }
        let exerciseCount = day.count
        let estimate = totalSets * 3 + exerciseCount * 4
        return min(max(estimate, 12), 120)
    }

    func totalSets(on date: Date, calendar: Calendar = .current) -> Int {
        workouts(on: date, calendar: calendar).reduce(0) { $0 + $1.sets.count }
    }

    func totalVolume(on date: Date, calendar: Calendar = .current) -> Double {
        workouts(on: date, calendar: calendar)
            .flatMap(\.sets)
            .reduce(0) { $0 + ($1.weight * Double($1.reps)) }
    }

    func personalRecordsCount(on date: Date, calendar: Calendar = .current) -> Int {
        let dayStart = calendar.startOfDay(for: date)
        return workouts(on: date, calendar: calendar).reduce(0) { count, entry in
            guard !entry.sets.isEmpty else { return count }
            let sessionMax = entry.sets.map(\.weight).max() ?? 0
            let historical = workouts
                .filter { !calendar.isDate($0.date, inSameDayAs: dayStart) }
                .filter { $0.exercise.name.caseInsensitiveCompare(entry.exercise.name) == .orderedSame }
                .flatMap(\.sets)
                .map(\.weight)
                .max() ?? 0
            return count + (sessionMax > historical ? 1 : 0)
        }
    }

    func volumeDeltaVsPreviousSession(for date: Date, calendar: Calendar = .current) -> Int? {
        guard let session = sessionName(for: date) else { return nil }
        let normalized = session.lowercased()
        let currentVolume = totalVolume(on: date, calendar: calendar)
        guard currentVolume > 0 else { return nil }

        var searchDay = calendar.startOfDay(for: date)
        for _ in 0..<90 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: searchDay) else { break }
            searchDay = previous
            guard !workouts(on: previous, calendar: calendar).isEmpty else { continue }
            let previousSession = sessionName(for: previous)?.lowercased() ?? ""
            guard previousSession.contains(normalized) || normalized.contains(previousSession) else { continue }
            let previousVolume = totalVolume(on: previous, calendar: calendar)
            guard previousVolume > 0 else { return nil }
            let delta = Int((currentVolume - previousVolume).rounded())
            return delta == 0 ? nil : delta
        }
        return nil
    }

    func recentWorkoutDaySummaries(limit: Int = 5) -> [RecentWorkoutDaySummary] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        var seen = Set<Date>()
        var results: [RecentWorkoutDaySummary] = []

        for workout in workouts {
            let day = calendar.startOfDay(for: workout.date)
            guard day < today, !seen.contains(day) else { continue }
            seen.insert(day)
            results.append(
                RecentWorkoutDaySummary(
                    date: day,
                    sessionName: displaySessionName(for: day) ?? "Workout",
                    durationMinutes: estimatedWorkoutMinutes(on: day),
                    totalSets: totalSets(on: day),
                    personalRecords: personalRecordsCount(on: day),
                    volumeDeltaVsPrevious: volumeDeltaVsPreviousSession(for: day)
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    func currentWorkoutStreak(calendar: Calendar = .current) -> Int {
        var count = 0
        var day = calendar.startOfDay(for: .now)

        if workouts(on: day, calendar: calendar).isEmpty {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }

        while !workouts(on: day, calendar: calendar).isEmpty {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    func workoutsThisWeekCount(calendar: Calendar = .current) -> Int {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        let days = Set(
            workouts
                .filter { $0.date >= weekStart }
                .map { calendar.startOfDay(for: $0.date) }
        )
        return days.count
    }

    func sessionCountThisWeek(matching keyword: String, calendar: Calendar = .current) -> Int {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        let normalized = keyword.lowercased()
        var seen = Set<Date>()
        var count = 0

        for workout in workouts where workout.date >= weekStart {
            let day = calendar.startOfDay(for: workout.date)
            guard seen.insert(day).inserted else { continue }
            let session = sessionName(for: day)?.lowercased() ?? ""
            if session.contains(normalized) || normalized.contains(session) {
                count += 1
            }
        }
        return count
    }

    func workoutsThisMonthCount(calendar: Calendar = .current) -> Int {
        guard let monthStart = calendar.dateInterval(of: .month, for: .now)?.start else { return 0 }
        let days = Set(
            workouts
                .filter { $0.date >= monthStart }
                .map { calendar.startOfDay(for: $0.date) }
        )
        return days.count
    }

    func daysSinceLastSession(matching keyword: String, before date: Date = .now, calendar: Calendar = .current) -> Int? {
        let target = calendar.startOfDay(for: date)
        let normalizedKeyword = keyword.lowercased()

        for workout in workouts {
            let day = calendar.startOfDay(for: workout.date)
            guard day < target else { continue }

            let session = sessionName(for: day)?.lowercased() ?? ""
            if session.contains(normalizedKeyword) || normalizedKeyword.contains(session) {
                return calendar.dateComponents([.day], from: day, to: target).day
            }

            let groups = Set(workouts(on: day, calendar: calendar).map(\.exercise.muscleGroup))
            if normalizedKeyword == "push", groups.isSubset(of: ["Chest", "Shoulders", "Arms"]), !groups.isEmpty {
                return calendar.dateComponents([.day], from: day, to: target).day
            }
            if normalizedKeyword == "pull", groups.contains("Back") {
                return calendar.dateComponents([.day], from: day, to: target).day
            }
            if normalizedKeyword == "legs", groups.contains("Legs") {
                return calendar.dateComponents([.day], from: day, to: target).day
            }
        }
        return nil
    }

    func daysSinceMuscleGroup(_ muscleGroup: String, before date: Date = .now, calendar: Calendar = .current) -> Int? {
        let target = calendar.startOfDay(for: date)
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.date)
            guard day < target else { continue }
            if workouts(on: day, calendar: calendar).contains(where: {
                $0.exercise.muscleGroup.caseInsensitiveCompare(muscleGroup) == .orderedSame
            }) {
                return calendar.dateComponents([.day], from: day, to: target).day
            }
        }
        return nil
    }

    func recoveryStatusLabel(consecutiveDays: Int? = nil) -> String {
        let streak = consecutiveDays ?? trainingStreakEndingToday()
        if streak >= 3 { return "Moderate load" }
        if streak >= 2 { return "Light day suggested" }
        return "Ready"
    }

    func trainingStreakEndingToday(calendar: Calendar = .current) -> Int {
        var count = 0
        var day = calendar.startOfDay(for: .now)
        while !workouts(on: day, calendar: calendar).isEmpty {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    func muscleGroups(for routine: WorkoutRoutine) -> [String] {
        var seen = Set<String>()
        return routine.sortedExercises.compactMap { item in
            let group = item.exercise.muscleGroup
            guard seen.insert(group).inserted else { return nil }
            return group
        }
    }

    func workoutFocusContext(profile: UserProfile, routine: WorkoutRoutine?) -> WorkoutFocusContext {
        WorkoutFocusContext(
            proteinCurrent: todaysProtein,
            proteinTarget: profile.proteinTarget,
            caloriesCurrent: todaysCalories,
            calorieTarget: profile.calorieTarget,
            isReadyToTrain: recoveryStatusLabel() == "Ready"
        )
    }

    private func routineKeyword(from name: String) -> String {
        for keyword in ["Push", "Pull", "Legs", "Upper", "Lower", "Full Body"] {
            if name.localizedCaseInsensitiveContains(keyword) {
                return keyword
            }
        }
        return name.replacingOccurrences(of: " Day", with: "", options: .caseInsensitive)
    }

    func preflightInfo(for routine: WorkoutRoutine) -> WorkoutPreflightInfo {
        let keyword = routineKeyword(from: routine.name)
        let previous = recentWorkoutDaySummaries(limit: 12).first { summary in
            summary.sessionName.localizedCaseInsensitiveContains(keyword)
                || keyword.localizedCaseInsensitiveContains(summary.sessionName)
        }

        return WorkoutPreflightInfo(
            estimatedMinutes: estimatedRoutineMinutes(routine),
            exerciseCount: routine.sortedExercises.count,
            previousWorkoutLabel: previous.map { DayHistory.displayTitle(for: $0.date) },
            lastDurationMinutes: previous?.durationMinutes
        )
    }

    func averageSessionMinutes(matching routine: WorkoutRoutine, withinDays: Int = 30) -> Int? {
        let keyword = routineKeyword(from: routine.name).lowercased()
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -withinDays, to: .now) else { return nil }

        var durations: [Int] = []
        var seen = Set<Date>()

        for workout in workouts where workout.date >= cutoff {
            let day = calendar.startOfDay(for: workout.date)
            guard seen.insert(day).inserted else { continue }
            let session = sessionName(for: day)?.lowercased() ?? ""
            guard session.contains(keyword) || keyword.contains(session) else { continue }
            let minutes = estimatedWorkoutMinutes(on: day)
            if minutes > 0 { durations.append(minutes) }
        }

        guard !durations.isEmpty else { return nil }
        return Int((Double(durations.reduce(0, +)) / Double(durations.count)).rounded())
    }

    func lastWorkoutEntry(for exerciseName: String) -> WorkoutEntry? {
        workouts.first { $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame }
    }

    func lastWorkoutEntry(for exerciseName: String, before date: Date) -> WorkoutEntry? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        return workouts.first {
            $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame
                && calendar.startOfDay(for: $0.date) < dayStart
                && !$0.sets.isEmpty
        }
    }

    func lastBestSet(for exerciseName: String) -> WorkoutSet? {
        guard let entry = lastWorkoutEntry(for: exerciseName) else { return nil }
        return entry.sets.max(by: { $0.weight < $1.weight })
    }

    func maxHistoricalWeight(for exerciseName: String) -> Double? {
        let weights = workouts
            .filter { $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame }
            .flatMap(\.sets)
            .map(\.weight)
        return weights.max()
    }

    func countPersonalRecords(in drafts: [RoutineExerciseDraft], on date: Date = .now) -> Int {
        let dayStart = Calendar.current.startOfDay(for: date)
        return drafts.reduce(0) { count, draft in
            guard !draft.sets.isEmpty else { return count }
            let sessionMax = draft.sets.map(\.weight).max() ?? 0
            let historical = workouts
                .filter { !Calendar.current.isDate($0.date, inSameDayAs: dayStart) }
                .filter { $0.exercise.name.caseInsensitiveCompare(draft.exercise.name) == .orderedSame }
                .flatMap(\.sets)
                .map(\.weight)
                .max() ?? 0
            return count + (sessionMax > historical ? 1 : 0)
        }
    }

    func totalVolumeLbs(in drafts: [RoutineExerciseDraft]) -> Double {
        drafts.flatMap(\.sets).reduce(0) { $0 + ($1.weight * Double($1.reps)) }
    }

    func weeklyWorkoutGoal() -> Int { 4 }

    func weeklyWorkoutProgress(calendar: Calendar = .current) -> (completed: Int, goal: Int, days: [Bool]) {
        let days = weeklyWorkoutMissionCompletion(calendar: calendar)
        let completed = days.filter { $0 }.count
        return (completed, weeklyWorkoutGoal(), days)
    }

    func averageRepChangeThisWeek(calendar: Calendar = .current) -> Int? {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start,
              let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: weekStart) else { return nil }

        let thisWeekSets = workouts
            .filter { $0.date >= weekStart }
            .flatMap(\.sets)
        let lastWeekSets = workouts
            .filter { $0.date >= lastWeekStart && $0.date < weekStart }
            .flatMap(\.sets)

        guard !thisWeekSets.isEmpty, !lastWeekSets.isEmpty else { return nil }

        let thisAvg = Double(thisWeekSets.reduce(0) { $0 + $1.reps }) / Double(thisWeekSets.count)
        let lastAvg = Double(lastWeekSets.reduce(0) { $0 + $1.reps }) / Double(lastWeekSets.count)
        return Int((thisAvg - lastAvg).rounded())
    }

    func consecutiveWeeksTrainingSession(matching keyword: String, calendar: Calendar = .current) -> Int {
        let normalized = keyword.lowercased()
        var weeks = 0
        var reference = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now

        while weeks < 12 {
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: reference) ?? reference
            let range = DateInterval(start: reference, end: weekEnd)
            let weekWorkouts = workouts(in: range, calendar: calendar)
            let sessionDays = Set(weekWorkouts.map { calendar.startOfDay(for: $0.date) })

            let matched = sessionDays.contains { day in
                let session = sessionName(for: day)?.lowercased() ?? ""
                return session.contains(normalized) || normalized.contains(session)
            }

            guard matched else { break }
            weeks += 1
            guard let previous = calendar.date(byAdding: .day, value: -7, to: reference) else { break }
            reference = previous
        }
        return weeks
    }

    func scheduledAssignment(for date: Date = .now) -> WorkoutScheduleAssignment {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekSchedule.assignment(forWeekday: weekday)
    }

    func isRestDay(for date: Date = .now) -> Bool {
        scheduledAssignment(for: date).kind == .rest
    }

    func scheduledRoutine(for date: Date = .now) -> WorkoutRoutine? {
        resolveRoutine(for: scheduledAssignment(for: date))
    }

    func resolveRoutine(for assignment: WorkoutScheduleAssignment) -> WorkoutRoutine? {
        guard assignment.kind != .rest, assignment.kind != .unassigned else { return nil }

        if let routineID = assignment.customRoutineID,
           let routine = routines.first(where: { $0.id == routineID }) {
            return routine
        }

        if assignment.kind == .custom { return nil }

        let available = routines.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !available.isEmpty else { return nil }

        for keyword in assignment.kind.matchKeywords {
            if let match = available.first(where: {
                $0.name.localizedCaseInsensitiveContains(keyword)
            }) {
                return match
            }
        }

        return nil
    }

    func updateWeekSchedule(_ schedule: WorkoutWeekSchedule) {
        weekSchedule = schedule
        persistWeekSchedule(schedule)
        syncScheduleToCloudIfNeeded()
    }

    private func syncScheduleToCloudIfNeeded() {
        guard let firestore,
              let profileSettings = try? context.fetch(FetchDescriptor<AppSettings>()).first,
              profileSettings.hasCompletedOnboarding else {
            print("[WorkoutSync] Schedule cloud sync skipped — firestore/onboarding unavailable")
            return
        }
        let profile = profileSettings.profile
        let scheduleJSON = persistedWorkoutScheduleJSON()
        let programDone = profileSettings.hasCompletedProgramSetup
        print("[WorkoutSync] Syncing schedule JSON to users/{uid} (\(scheduleJSON.count) chars)")
        syncToFirestoreIfNeeded(label: "saveUserProfile.schedule") { db in
            try await db.saveUserProfile(
                profile,
                hasCompletedOnboarding: true,
                hasCompletedProgramSetup: programDone,
                workoutScheduleJSON: scheduleJSON
            )
        }
    }

    func setScheduleAssignment(_ assignment: WorkoutScheduleAssignment, forWeekday weekday: Int) {
        var schedule = weekSchedule
        schedule.setAssignment(assignment, forWeekday: weekday)
        updateWeekSchedule(schedule)
    }

    func schedulePreview(routines: [WorkoutRoutine], on date: Date = .now) -> WorkoutSchedulePreview {
        let today = scheduledAssignment(for: date)
        let todayTitle = today.displayTitle(matching: routines)
        let calendar = Calendar.current

        for offset in 1...7 {
            guard let nextDate = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let weekday = calendar.component(.weekday, from: nextDate)
            let assignment = weekSchedule.assignment(forWeekday: weekday)
            guard assignment.kind != .rest, assignment.kind != .unassigned else { continue }
            return WorkoutSchedulePreview(
                todayTitle: todayTitle,
                nextTitle: assignment.displayTitle(matching: routines),
                nextDayAbbrev: WorkoutScheduleFormatters.weekdayName(for: nextDate, short: true),
                nextWeekdayName: WorkoutScheduleFormatters.weekdayName(for: nextDate)
            )
        }

        return WorkoutSchedulePreview(todayTitle: todayTitle, nextTitle: nil, nextDayAbbrev: nil, nextWeekdayName: nil)
    }

    private func loadWeekSchedule() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first,
              !settings.workoutScheduleJSON.isEmpty,
              let data = settings.workoutScheduleJSON.data(using: .utf8),
              let schedule = try? JSONDecoder().decode(WorkoutWeekSchedule.self, from: data),
              schedule.days.count == 7 else {
            weekSchedule = .blank
            return
        }
        weekSchedule = schedule
    }

    private func persistWeekSchedule(_ schedule: WorkoutWeekSchedule) {
        guard let data = try? JSONEncoder().encode(schedule),
              let json = String(data: data, encoding: .utf8) else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.workoutScheduleJSON = json
        try? context.save()
    }

    private func loadSessionLabels() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first,
              !settings.sessionLabelsJSON.isEmpty,
              let data = settings.sessionLabelsJSON.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String: String].self, from: data) else {
            sessionLabelsByDay = [:]
            return
        }
        sessionLabelsByDay = labels
    }

    private func persistSessionLabels() {
        guard let data = try? JSONEncoder().encode(sessionLabelsByDay),
              let json = String(data: data, encoding: .utf8) else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.sessionLabelsJSON = json
        try? context.save()
    }

    private func loadDayTemplateAssignments() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first,
              !settings.dayTemplateAssignmentsJSON.isEmpty,
              let data = settings.dayTemplateAssignmentsJSON.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            dayTemplateRoutineIDs = [:]
            return
        }
        dayTemplateRoutineIDs = raw.compactMapValues { UUID(uuidString: $0) }
    }

    private func persistDayTemplateAssignments() {
        let raw = dayTemplateRoutineIDs.mapValues(\.uuidString)
        guard let data = try? JSONEncoder().encode(raw),
              let json = String(data: data, encoding: .utf8) else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.dayTemplateAssignmentsJSON = json
        try? context.save()
    }

    private func loadActiveDayTemplateKinds() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first,
              !settings.dayTemplateKindsJSON.isEmpty,
              let data = settings.dayTemplateKindsJSON.data(using: .utf8),
              let kinds = try? JSONDecoder().decode([String: String].self, from: data) else {
            activeDayTemplateKinds = [:]
            return
        }
        activeDayTemplateKinds = kinds
    }

    private func persistActiveDayTemplateKinds() {
        guard let data = try? JSONEncoder().encode(activeDayTemplateKinds),
              let json = String(data: data, encoding: .utf8) else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.dayTemplateKindsJSON = json
        try? context.save()
    }

    func scheduledRoutineProgress(for date: Date, routine: WorkoutRoutine) -> (completed: Int, total: Int) {
        let loggedNames = Set(workouts(on: date).map { $0.exercise.name.lowercased() })
        let total = routine.sortedExercises.count
        let completed = routine.sortedExercises.filter {
            loggedNames.contains($0.exercise.name.lowercased())
        }.count
        return (completed, total)
    }

    func currentWorkoutPosition(for routine: WorkoutRoutine, on date: Date) -> WorkoutSetPosition? {
        let logged = workouts(on: date)
        let exercises = routine.sortedExercises
        guard !exercises.isEmpty else { return nil }

        let assumedSetsPerExercise = 3

        for (index, item) in exercises.enumerated() {
            if let entry = logged.first(where: {
                $0.exercise.name.caseInsensitiveCompare(item.exercise.name) == .orderedSame
            }) {
                let completedSets = entry.sets.count
                if completedSets < assumedSetsPerExercise {
                    return WorkoutSetPosition(
                        exerciseName: item.exercise.name,
                        currentSet: completedSets + 1,
                        totalSets: assumedSetsPerExercise,
                        exerciseIndex: index,
                        exerciseCount: exercises.count
                    )
                }
            } else {
                return WorkoutSetPosition(
                    exerciseName: item.exercise.name,
                    currentSet: 1,
                    totalSets: assumedSetsPerExercise,
                    exerciseIndex: index,
                    exerciseCount: exercises.count
                )
            }
        }
        return nil
    }

    func estimatedRoutineMinutes(_ routine: WorkoutRoutine) -> Int {
        let exercises = routine.sortedExercises.count
        guard exercises > 0 else { return 0 }
        let assumedSetsPerExercise = 4
        let totalSets = exercises * assumedSetsPerExercise
        return max(totalSets * 3 + exercises * 4, 15)
    }

    var todaysExerciseCount: Int {
        todaysWorkouts.count
    }

    var todaysSetCount: Int {
        todaysWorkouts.reduce(0) { $0 + $1.sets.count }
    }

    func estimatedTodayWorkoutMinutes() -> Int {
        let today = todaysWorkouts
        guard !today.isEmpty else { return 0 }

        let totalSets = today.reduce(0) { $0 + $1.sets.count }
        let setEstimate = totalSets * 3

        guard today.count > 1 else {
            return max(setEstimate, 20)
        }

        let sorted = today.sorted { $0.date < $1.date }
        let spanMinutes = Int(sorted.last!.date.timeIntervalSince(sorted.first!.date) / 60)
        return max(setEstimate, spanMinutes + totalSets * 2, 15)
    }

    func recentWeightTrend(limit: Int = 8) -> [Double] {
        Array(weights.prefix(limit).map(\.weight).reversed())
    }

    func proteinGoalMet(on date: Date, target: Int, calendar: Calendar = .current) -> Bool {
        let dayFoods = foods(on: date, calendar: calendar)
        let protein = dayFoods.reduce(0) { $0 + $1.protein }
        return protein >= target
    }

    func workoutGoalMet(on date: Date, calendar: Calendar = .current) -> Bool {
        workouts(on: date, calendar: calendar).contains { !$0.sets.isEmpty }
    }

    func weeklyProteinMissionCompletion(
        target: Int,
        calendar: Calendar = .current
    ) -> [Bool] {
        let today = calendar.startOfDay(for: .now)
        return DayHistory.mondayToSundayDates(calendar: calendar).map { day in
            guard day <= today else { return false }
            return proteinGoalMet(on: day, target: target, calendar: calendar)
        }
    }

    func weeklyWorkoutMissionCompletion(calendar: Calendar = .current) -> [Bool] {
        let today = calendar.startOfDay(for: .now)
        return DayHistory.mondayToSundayDates(calendar: calendar).map { day in
            guard day <= today else { return false }
            return workoutGoalMet(on: day, calendar: calendar)
        }
    }

    func weeklyConsistencySummary(
        proteinTarget: Int,
        calendar: Calendar = .current
    ) -> (workoutDays: Int, proteinDays: Int, eligibleDays: Int, workoutFlags: [Bool], proteinFlags: [Bool]) {
        let workoutFlags = weeklyWorkoutMissionCompletion(calendar: calendar)
        let proteinFlags = weeklyProteinMissionCompletion(target: proteinTarget, calendar: calendar)
        let today = calendar.startOfDay(for: .now)
        let weekDates = DayHistory.mondayToSundayDates(calendar: calendar)
        let eligibleDays = weekDates.filter { $0 <= today }.count
        let workoutDays = workoutFlags.filter { $0 }.count
        let proteinDays = proteinFlags.filter { $0 }.count
        return (workoutDays, proteinDays, max(eligibleDays, 1), workoutFlags, proteinFlags)
    }

    func weeklyOverallMissionCompletion(
        proteinTarget: Int,
        calendar: Calendar = .current
    ) -> [Bool] {
        let protein = weeklyProteinMissionCompletion(target: proteinTarget, calendar: calendar)
        let workout = weeklyWorkoutMissionCompletion(calendar: calendar)
        return zip(protein, workout).map { $0 && $1 }
    }

    enum WeeklyDayConsistency: Equatable {
        case empty
        case proteinOnly
        case workout
    }

    func weeklyConsistencyStates(
        proteinTarget: Int,
        calendar: Calendar = .current
    ) -> [WeeklyDayConsistency] {
        let today = calendar.startOfDay(for: .now)
        return DayHistory.mondayToSundayDates(calendar: calendar).map { day in
            guard day <= today else { return .empty }
            let workoutDone = workoutGoalMet(on: day, calendar: calendar)
            let proteinDone = proteinGoalMet(on: day, target: proteinTarget, calendar: calendar)
            if workoutDone { return .workout }
            if proteinDone { return .proteinOnly }
            return .empty
        }
    }

    func exercisesWithLoggedSetsCount(on date: Date, calendar: Calendar = .current) -> Int {
        workouts(on: date, calendar: calendar).filter { !$0.sets.isEmpty }.count
    }

    func plannedExerciseCount(for date: Date) -> Int {
        let planned = routineExerciseCount(for: date)
        if planned > 0 { return planned }
        return workouts(on: date).count
    }

    func workouts(in range: DateInterval, calendar: Calendar = .current) -> [WorkoutEntry] {
        workouts.filter { workout in
            workout.date >= range.start && workout.date < range.end
        }
    }

    func foods(in range: DateInterval, calendar: Calendar = .current) -> [FoodEntry] {
        foods.filter { food in
            food.date >= range.start && food.date < range.end
        }
    }

    func workouts(on date: Date, calendar: Calendar = .current) -> [WorkoutEntry] {
        let day = calendar.startOfDay(for: date)
        return workouts.filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date > $1.date }
    }

    func foods(on date: Date, calendar: Calendar = .current) -> [FoodEntry] {
        foods.filter { calendar.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.date > $1.date }
    }

    func foods(on date: Date, meal: MealType, calendar: Calendar = .current) -> [FoodEntry] {
        foods(on: date, calendar: calendar).filter { $0.meal == meal }
    }

    func mealCalories(on date: Date, meal: MealType, calendar: Calendar = .current) -> Int {
        foods(on: date, meal: meal, calendar: calendar).reduce(0) { $0 + $1.calories }
    }

    func recentlyUsedFoods(limit: Int = 10) -> [FoodLibraryItem] {
        var seen = Set<String>()
        var result: [FoodLibraryItem] = []
        for entry in foods {
            let key = entry.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(
                FoodLibraryItem(
                    name: entry.name,
                    brand: "Recent",
                    calories: Double(max(entry.calories, 1)),
                    protein: Double(entry.protein),
                    carbs: Double(entry.carbs),
                    fat: Double(entry.fat)
                )
            )
            if result.count >= limit { break }
        }
        return result
    }

    func macroTotals(for foods: [FoodEntry]) -> (calories: Int, protein: Int, carbs: Int, fat: Int) {
        (
            calories: foods.reduce(0) { $0 + $1.calories },
            protein: foods.reduce(0) { $0 + $1.protein },
            carbs: foods.reduce(0) { $0 + $1.carbs },
            fat: foods.reduce(0) { $0 + $1.fat }
        )
    }

    func workoutCount(in range: DateInterval) -> Int {
        workouts(in: range).count
    }

    func nutritionDaysLogged(in range: DateInterval, calendar: Calendar = .current) -> Int {
        Set(foods(in: range).map { calendar.startOfDay(for: $0.date) }).count
    }

    func reload() {
        workouts = fetchWorkouts()
        deduplicateWorkoutsOnSameDays()
        foods = fetchFoods()
        refreshCurrentCalendarDayIfNeeded()
        weights = fetchWeights()
        progressPhotos = fetchProgressPhotos()
        coaches = fetchCoaches()
        exercises = fetchExercises()
        savedMeals = fetchSavedMeals()
        routines = fetchRoutines()
        migrateRoutineExerciseOwnership()
        loadWeekSchedule()
        loadSessionLabels()
        loadDayTemplateAssignments()
        loadActiveDayTemplateKinds()
        loadSuppressDayTemplateAutoSeed()
        loadCompletedWorkoutDays()
        validateDayTemplateAssignments()
        seedDefaultDayTemplateAssignmentsIfNeeded()
        purgeOffCategoryExercisesForAllScheduledDays()
    }

    private func validateDayTemplateAssignments() {
        var changed = false

        for kind in allSplittableKinds() {
            guard let id = dayTemplateRoutineIDs[kind.rawValue] else { continue }
            guard routines.contains(where: { $0.id == id }) else {
                dayTemplateRoutineIDs.removeValue(forKey: kind.rawValue)
                changed = true
                continue
            }
        }

        if changed {
            persistDayTemplateAssignments()
        }
    }

    private func seedDefaultDayTemplateAssignmentsIfNeeded() {
        guard !suppressDayTemplateAutoSeed else { return }
        guard dayTemplateRoutineIDs.isEmpty, !routines.isEmpty else { return }

        for kind in allSplittableKinds() {
            let preferredName = "\(kind.displayName) Day"
            guard let routine = routines.first(where: {
                $0.name.caseInsensitiveCompare(preferredName) == .orderedSame
            }) else { continue }
            dayTemplateRoutineIDs[kind.rawValue] = routine.id
        }
        persistDayTemplateAssignments()
    }

    private func loadSuppressDayTemplateAutoSeed() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else {
            suppressDayTemplateAutoSeed = false
            return
        }
        suppressDayTemplateAutoSeed = settings.suppressDayTemplateAutoSeed
    }

    private func persistSuppressDayTemplateAutoSeed() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.suppressDayTemplateAutoSeed = suppressDayTemplateAutoSeed
        try? context.save()
    }

    func mergeCloudData(
        weights cloudWeights: [WeightEntry],
        meals cloudMeals: [FoodEntry],
        workouts cloudWorkouts: [WorkoutEntry]
    ) {
        for entry in cloudWeights where !weights.contains(where: { $0.id == entry.id }) {
            context.insert(WeightRecord(from: entry))
        }

        for entry in cloudMeals where !foods.contains(where: { $0.id == entry.id }) {
            context.insert(FoodRecord(from: entry))
        }

        for entry in cloudWorkouts where !workouts.contains(where: { $0.id == entry.id }) {
            context.insert(WorkoutRecord(from: entry))
        }

        saveAndReload()
    }

    /// Replaces local meal/workout/weight/routine history with the authenticated user's cloud data.
    /// Use on session restore so a previous account's logs cannot remain mixed in.
    func replaceCloudData(
        weights cloudWeights: [WeightEntry],
        meals cloudMeals: [FoodEntry],
        workouts cloudWorkouts: [WorkoutEntry],
        routines cloudRoutines: [WorkoutRoutine] = []
    ) {
        deleteAllRecords(of: WorkoutRecord.self)
        deleteAllRecords(of: FoodRecord.self)
        deleteAllRecords(of: WeightRecord.self)

        // Only replace routines when cloud returned any — avoids wiping local library
        // on a transient empty fetch for accounts that haven't synced routines yet.
        if !cloudRoutines.isEmpty {
            deleteAllRecords(of: WorkoutRoutineRecord.self)
            deleteAllRecords(of: RoutineExerciseRecord.self)
            for routine in cloudRoutines {
                context.insert(WorkoutRoutineRecord(from: routine))
            }
            print("[WorkoutSync] Replaced local routines from cloud count=\(cloudRoutines.count) ids=\(cloudRoutines.map(\.id.uuidString).joined(separator: ","))")
        } else {
            print("[WorkoutSync] Cloud routines empty — keeping local routine library")
        }

        for entry in cloudWeights {
            context.insert(WeightRecord(from: entry))
        }
        for entry in cloudMeals {
            context.insert(FoodRecord(from: entry))
        }
        for entry in cloudWorkouts {
            context.insert(WorkoutRecord(from: entry))
        }

        saveAndReload()
    }

    /// Removes all locally cached data for the signed-out or previous account.
    /// Routines, schedules, workouts, nutrition, and progress are device-local and
    /// must be cleared whenever the authenticated Firebase user changes.
    func clearAllLocalUserData() {
        for photo in fetchProgressPhotos() {
            ProgressPhotoStorage.delete(fileName: photo.fileName, userId: photo.userId)
        }

        deleteAllRecords(of: WorkoutRecord.self)
        deleteAllRecords(of: FoodRecord.self)
        deleteAllRecords(of: WeightRecord.self)
        deleteAllRecords(of: WorkoutRoutineRecord.self)
        deleteAllRecords(of: RoutineExerciseRecord.self)
        deleteAllRecords(of: SavedMealRecord.self)
        deleteAllRecords(of: MealComponentRecord.self)
        deleteAllRecords(of: ProgressPhotoRecord.self)

        resetUserScopedSettings()
        reload()
    }

    private func deleteAllRecords<Record: PersistentModel>(of type: Record.Type) {
        let descriptor = FetchDescriptor<Record>()
        guard let records = try? context.fetch(descriptor) else { return }
        for record in records {
            context.delete(record)
        }
    }

    private func resetUserScopedSettings() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }

        let preservedAppearance = settings.appearance
        let preservedRestTimer = settings.restTimerSeconds
        let preservedMacroStyle = settings.nutritionMacroDisplayStyle
        let preservedHealthSync = settings.appleHealthSyncEnabled
        let preservedSubscriber = settings.isSyncFitPlusSubscriber

        settings.profile = UserProfile()
        settings.hasCompletedOnboarding = false
        settings.hasCompletedProgramSetup = false
        settings.hasCoach = false
        settings.workoutScheduleJSON = ""
        settings.sessionLabelsJSON = ""
        settings.dayTemplateAssignmentsJSON = ""
        settings.dayTemplateKindsJSON = ""
        settings.completedWorkoutDaysJSON = ""
        settings.exerciseNotesJSON = ""
        settings.suppressDayTemplateAutoSeed = false
        settings.hiredCoachID = ""
        settings.coachPortalProfileJSON = ""
        settings.coachSessionID = ""
        settings.coachModeActive = false
        settings.userIsCoach = false
        settings.isAuthenticated = false

        settings.appearance = preservedAppearance
        settings.restTimerSeconds = preservedRestTimer
        settings.nutritionMacroDisplayStyle = preservedMacroStyle
        settings.appleHealthSyncEnabled = preservedHealthSync
        settings.isSyncFitPlusSubscriber = preservedSubscriber

        try? context.save()
    }

    func searchExercises(
        query: String,
        muscleGroup: String? = nil,
        splitKind: WorkoutScheduleKind? = nil
    ) -> [Exercise] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let splitGroups = splitKind?.filterMuscleGroups
        return exercises.filter { exercise in
            if let splitGroups {
                guard splitGroups.contains(exercise.muscleGroup) else { return false }
            }
            let matchesGroup = muscleGroup.map { exercise.muscleGroup == $0 } ?? true
            guard matchesGroup else { return false }
            guard !trimmed.isEmpty else { return true }
            return exercise.name.localizedCaseInsensitiveContains(trimmed)
                || exercise.muscleGroup.localizedCaseInsensitiveContains(trimmed)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func recentlyUsedExercises(limit: Int = 4) -> [Exercise] {
        var seen = Set<String>()
        var result: [Exercise] = []
        let ordered = workouts.sorted { $0.date > $1.date }
        for entry in ordered {
            let key = entry.exercise.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            if let match = exercises.first(where: {
                $0.name.caseInsensitiveCompare(entry.exercise.name) == .orderedSame
            }) {
                result.append(match)
            } else {
                result.append(entry.exercise)
            }
            if result.count >= limit { break }
        }
        return result
    }

    func addWorkout(_ entry: WorkoutEntry) {
        var normalized = entry
        normalized.date = Calendar.current.startOfDay(for: entry.date)

        if mergeIntoExistingWorkout(normalized) {
            markWorkoutInProgress(for: normalized.date)
            saveAndReload()
            syncDayWorkoutIfNeeded(on: normalized.date)
            return
        }

        context.insert(WorkoutRecord(from: normalized))
        markWorkoutInProgress(for: normalized.date)
        saveAndReload()
        syncDayWorkoutIfNeeded(on: normalized.date)
        syncToFirestoreIfNeeded(label: "saveWorkout.add") { try await $0.saveWorkout(normalized) }
    }

    @discardableResult
    private func mergeIntoExistingWorkout(_ entry: WorkoutEntry) -> Bool {
        guard let existing = workouts.first(where: {
            Calendar.current.isDate($0.date, inSameDayAs: entry.date)
                && $0.exercise.name.caseInsensitiveCompare(entry.exercise.name) == .orderedSame
        }) else { return false }

        var updated = existing
        let incomingHasWeightedSet = entry.sets.contains { $0.weight > 0 }
        if incomingHasWeightedSet {
            updated.sets.removeAll { $0.weight == 0 }
        }
        updated.sets.append(contentsOf: entry.sets)
        if !entry.notes.isEmpty, updated.notes.isEmpty {
            updated.notes = entry.notes
        }

        let targetID = updated.id
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return false }

        record.exerciseName = updated.exercise.name
        record.muscleGroup = updated.exercise.muscleGroup
        record.date = Calendar.current.startOfDay(for: updated.date)
        record.notes = updated.notes

        for set in record.sets {
            context.delete(set)
        }
        let newSets = updated.sets.map { WorkoutSetRecord(from: $0) }
        record.sets = newSets
        for set in newSets {
            set.workout = record
        }

        syncToFirestoreIfNeeded(label: "saveWorkout.merge") { try await $0.saveWorkout(updated) }
        return true
    }

    private func deduplicateWorkoutsOnSameDays() {
        var grouped: [String: [WorkoutEntry]] = [:]
        for entry in workouts {
            let key = "\(Self.dayKey(for: entry.date))|\(entry.exercise.name.lowercased())"
            grouped[key, default: []].append(entry)
        }

        var didChange = false
        for duplicates in grouped.values where duplicates.count > 1 {
            guard var merged = duplicates.first else { continue }
            merged.sets = duplicates.flatMap(\.sets)
            merged.notes = duplicates.map(\.notes).first(where: { !$0.isEmpty }) ?? merged.notes

            let targetID = merged.id
            var descriptor = FetchDescriptor<WorkoutRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            guard let record = try? context.fetch(descriptor).first else { continue }

            for set in record.sets {
                context.delete(set)
            }
            let newSets = merged.sets.map { WorkoutSetRecord(from: $0) }
            record.sets = newSets
            for set in newSets {
                set.workout = record
            }

            for duplicate in duplicates.dropFirst() {
                let duplicateID = duplicate.id
                var duplicateDescriptor = FetchDescriptor<WorkoutRecord>(
                    predicate: #Predicate { $0.id == duplicateID }
                )
                if let duplicateRecord = try? context.fetch(duplicateDescriptor).first {
                    context.delete(duplicateRecord)
                }
            }
            didChange = true
        }

        if didChange {
            try? context.save()
            workouts = fetchWorkouts()
        }
    }

    func appendSetToWorkout(exercise: Exercise, set: WorkoutSet, on date: Date = .now) {
        let dayStart = Calendar.current.startOfDay(for: date)
        markWorkoutInProgress(for: dayStart)
        if let existing = workouts.first(where: {
            Calendar.current.isDate($0.date, inSameDayAs: dayStart)
                && $0.exercise.name.caseInsensitiveCompare(exercise.name) == .orderedSame
        }) {
            var updated = existing
            if set.weight > 0 {
                updated.sets.removeAll { $0.weight == 0 }
            }
            updated.sets.append(set)
            updateWorkout(updated)
        } else {
            addWorkout(WorkoutEntry(exercise: exercise, sets: [set], date: dayStart))
        }
    }

    func removeSetFromWorkout(exercise: Exercise, at index: Int, on date: Date = .now) {
        let dayStart = Calendar.current.startOfDay(for: date)
        guard let existing = workouts.first(where: {
            Calendar.current.isDate($0.date, inSameDayAs: dayStart)
                && $0.exercise.name.caseInsensitiveCompare(exercise.name) == .orderedSame
        }), existing.sets.indices.contains(index) else { return }

        var updated = existing
        updated.sets.remove(at: index)

        if updated.sets.isEmpty {
            deleteWorkout(updated)
        } else {
            updateWorkout(updated)
        }
    }

    func addWorkouts(_ entries: [WorkoutEntry]) {
        let calendar = Calendar.current
        let normalized = entries.map { entry -> WorkoutEntry in
            var copy = entry
            copy.date = calendar.startOfDay(for: entry.date)
            return copy
        }

        var needsReload = false
        for entry in normalized {
            if mergeIntoExistingWorkout(entry) {
                needsReload = true
            } else {
                context.insert(WorkoutRecord(from: entry))
                needsReload = true
            }
        }

        if needsReload {
            saveAndReload()
            if let date = normalized.first?.date {
                syncDayWorkoutIfNeeded(on: date)
            }
            for entry in normalized {
                syncToFirestoreIfNeeded(label: "saveWorkout.batch") { try await $0.saveWorkout(entry) }
            }
        }
    }

    func deleteWorkout(_ entry: WorkoutEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        saveAndReload()
        syncToFirestoreIfNeeded(label: "deleteWorkout") { try await $0.deleteWorkout(entry) }
    }

    func deleteWorkouts(at offsets: IndexSet) {
        for index in offsets {
            deleteWorkout(workouts[index])
        }
    }

    func updateWorkout(_ entry: WorkoutEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }

        record.exerciseName = entry.exercise.name
        record.muscleGroup = entry.exercise.muscleGroup
        record.date = Calendar.current.startOfDay(for: entry.date)
        record.notes = entry.notes
        record.plannedSetsJSON = WorkoutRecord.encodePlannedSets(entry.plannedSets)

        for set in record.sets {
            context.delete(set)
        }
        let newSets = entry.sets.map { WorkoutSetRecord(from: $0) }
        record.sets = newSets
        for set in newSets {
            set.workout = record
        }

        saveAndReload()
        syncToFirestoreIfNeeded(label: "saveWorkout.update") { try await $0.saveWorkout(entry) }
    }

    func updateWorkoutPlan(_ entry: WorkoutEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }

        record.exerciseName = entry.exercise.name
        record.muscleGroup = entry.exercise.muscleGroup
        record.plannedSetsJSON = WorkoutRecord.encodePlannedSets(entry.plannedSets)
        saveAndReload()
    }

    func addFood(_ entry: FoodEntry) {
        var normalized = entry
        normalized.date = Calendar.current.startOfDay(for: entry.date)
        context.insert(FoodRecord(from: normalized))
        saveAndReload()
        syncToHealthIfNeeded { await $0.syncFood(normalized) }
        syncToFirestoreIfNeeded { try await $0.saveMeal(normalized) }
    }

    func updateFood(_ entry: FoodEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<FoodRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }

        record.name = entry.name
        record.calories = entry.calories
        record.protein = entry.protein
        record.carbs = entry.carbs
        record.fat = entry.fat
        record.meal = entry.meal
        record.date = Calendar.current.startOfDay(for: entry.date)
        record.servingLabel = entry.servingLabel
        saveAndReload()
        syncToFirestoreIfNeeded { try await $0.saveMeal(entry) }
    }

    func deleteFood(_ entry: FoodEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<FoodRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        saveAndReload()
        syncToFirestoreIfNeeded { try await $0.deleteMeal(entry) }
    }

    func deleteFoods(at offsets: IndexSet, in foods: [FoodEntry]) {
        for index in offsets {
            deleteFood(foods[index])
        }
    }

    func addSavedMeal(_ meal: SavedMeal) {
        context.insert(SavedMealRecord(from: meal))
        saveAndReload()
    }

    func updateSavedMeal(_ meal: SavedMeal) {
        let targetID = meal.id
        var descriptor = FetchDescriptor<SavedMealRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }

        record.name = meal.name
        for component in record.components {
            context.delete(component)
        }
        let newComponents = meal.components.map { MealComponentRecord(from: $0) }
        record.components = newComponents
        for component in newComponents {
            component.savedMeal = record
        }
        saveAndReload()
    }

    func deleteSavedMeal(_ meal: SavedMeal) {
        let targetID = meal.id
        var descriptor = FetchDescriptor<SavedMealRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        saveAndReload()
    }

    func logSavedMeal(_ meal: SavedMeal, as mealType: MealType, on date: Date = .now) {
        let entry = FoodEntry(
            name: meal.name,
            calories: meal.totalCalories,
            protein: meal.totalProtein,
            carbs: meal.totalCarbs,
            fat: meal.totalFat,
            meal: mealType,
            date: Calendar.current.startOfDay(for: date)
        )
        addFood(entry)
    }

    func addRoutine(_ routine: WorkoutRoutine) {
        print("[WorkoutSync] PART2 addRoutine id=\(routine.id.uuidString) name=\(routine.name) exercises=\(routine.exercises.count)")
        let record = WorkoutRoutineRecord(from: routine)
        context.insert(record)
        saveAndReload()
        syncToFirestoreIfNeeded(label: "saveRoutine.add") { try await $0.saveRoutine(routine) }
    }

    func updateRoutine(_ routine: WorkoutRoutine) {
        print("[WorkoutSync] PART2 updateRoutine id=\(routine.id.uuidString) name=\(routine.name) exercises=\(routine.exercises.count)")
        let targetID = routine.id
        var descriptor = FetchDescriptor<WorkoutRoutineRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else {
            print("[WorkoutSync] PART2 updateRoutine FAILED — no local record for id=\(targetID.uuidString)")
            return
        }

        record.name = routine.name

        let existingDescriptor = FetchDescriptor<RoutineExerciseRecord>(
            predicate: #Predicate { $0.routineID == targetID }
        )
        let existing = (try? context.fetch(existingDescriptor)) ?? []
        for exercise in existing {
            context.delete(exercise)
        }

        let newExercises = routine.exercises.map {
            RoutineExerciseRecord(from: $0, routineID: routine.id)
        }
        record.exercises = newExercises
        for exercise in newExercises {
            exercise.routine = record
        }
        saveAndReload()
        syncToFirestoreIfNeeded(label: "saveRoutine.update") { try await $0.saveRoutine(routine) }
    }

    func routine(with id: UUID) -> WorkoutRoutine? {
        var descriptor = FetchDescriptor<WorkoutRoutineRecord>(
            predicate: #Predicate { $0.id == id }
        )
        guard let record = try? context.fetch(descriptor).first else { return nil }
        return fetchRoutine(for: record)
    }

    var needsProgramOnboarding: Bool {
        // After session restore, hasCompletedProgramSetup comes from this UID's cloud doc
        // (or stays false for a wiped new account). Do not treat leftover local routines
        // as "setup complete" — that was a cross-account contamination path.
        guard !hasCompletedProgramSetup else { return false }
        // Same-user safety: if this device already has a real schedule for the current
        // owner, don't force the program flow (it can replace the weekly plan).
        if weekSchedule.days.contains(where: { $0.kind != .unassigned }) { return false }
        return true
    }

    var hasCompletedProgramSetup: Bool {
        let descriptor = FetchDescriptor<AppSettings>()
        return (try? context.fetch(descriptor).first?.hasCompletedProgramSetup) ?? false
    }

    func markProgramSetupComplete() {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.hasCompletedProgramSetup = true
        settings.suppressDayTemplateAutoSeed = true
        try? context.save()
        objectWillChange.send()
    }

    /// Restores program-setup completion and weekly schedule from the authenticated user's cloud doc.
    func applyCloudProgramState(hasCompletedProgramSetup: Bool, workoutScheduleJSON: String) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }

        if hasCompletedProgramSetup {
            settings.hasCompletedProgramSetup = true
            settings.suppressDayTemplateAutoSeed = true
        }

        if !workoutScheduleJSON.isEmpty,
           let data = workoutScheduleJSON.data(using: .utf8),
           let schedule = try? JSONDecoder().decode(WorkoutWeekSchedule.self, from: data),
           schedule.days.count == 7 {
            settings.workoutScheduleJSON = workoutScheduleJSON
            weekSchedule = schedule
        }

        try? context.save()
        objectWillChange.send()
    }

    func persistedWorkoutScheduleJSON() -> String {
        let descriptor = FetchDescriptor<AppSettings>()
        if let stored = try? context.fetch(descriptor).first?.workoutScheduleJSON,
           !stored.isEmpty {
            return stored
        }
        guard let data = try? JSONEncoder().encode(weekSchedule),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    func importProgramTemplate(_ template: ProgramTemplate, replaceExisting: Bool = true) {
        if replaceExisting {
            for routine in routines {
                deleteRoutine(routine)
            }
            clearNonManualWorkouts()
            activeDayTemplateKinds.removeAll()
            sessionLabelsByDay.removeAll()
            persistActiveDayTemplateKinds()
            persistSessionLabels()
            updateWeekSchedule(.blank)
        }

        var routinesByName: [String: WorkoutRoutine] = [:]

        for spec in template.uniqueRoutineDays() {
            let items = spec.exercises.enumerated().map { index, exerciseSpec in
                let exercise = ProgramTemplateLibrary.resolveExercise(named: exerciseSpec.name)
                return RoutineExerciseItem(
                    exercise: exercise,
                    sortOrder: index,
                    plannedSetCount: exerciseSpec.setCount,
                    plannedReps: exerciseSpec.reps,
                    plannedWeight: exercise.isBodyweight ? 0 : nil
                )
            }
            let routine = WorkoutRoutine(name: spec.name, exercises: items)
            addRoutine(routine)
            routinesByName[spec.name] = routine
        }

        for day in template.days {
            if day.isRest {
                assignRest(toWeekday: day.weekday)
                continue
            }
            guard let routine = routinesByName[day.routineName] else { continue }
            assignRoutine(routine, toWeekday: day.weekday)
        }

        for day in template.trainingDays {
            guard let routine = routinesByName[day.routineName] else { continue }
            let date = dateForWeekday(day.weekday)
            syncDayPlanToRoutine(routine, on: date)
        }

        markProgramSetupComplete()
        objectWillChange.send()
    }

    func deleteRoutine(_ routine: WorkoutRoutine) {
        let targetID = routine.id
        print("[WorkoutSync] deleteRoutine id=\(targetID.uuidString)")
        unassignRoutineFromSchedule(routineID: targetID)
        removeDayTemplateLinks(forRoutineID: targetID)

        var descriptor = FetchDescriptor<WorkoutRoutineRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        saveAndReload()
        syncToFirestoreIfNeeded(label: "deleteRoutine") { try await $0.deleteRoutine(routine) }
    }

    private func unassignRoutineFromSchedule(routineID: UUID) {
        var schedule = weekSchedule
        var changed = false

        for index in schedule.days.indices {
            let assignment = schedule.days[index]
            guard assignment.kind != .rest, assignment.kind != .unassigned else { continue }

            if assignment.customRoutineID == routineID {
                schedule.days[index] = .unassigned
                changed = true
                continue
            }

            if resolveRoutine(for: assignment)?.id == routineID {
                schedule.days[index] = .unassigned
                changed = true
            }
        }

        if changed {
            updateWeekSchedule(schedule)
        }
    }

    private func removeDayTemplateLinks(forRoutineID: UUID) {
        let keysToRemove = dayTemplateRoutineIDs.filter { $0.value == forRoutineID }.map(\.key)
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            dayTemplateRoutineIDs.removeValue(forKey: key)
        }
        persistDayTemplateAssignments()
    }

    func logRoutine(_ routine: WorkoutRoutine, drafts: [RoutineExerciseDraft], on date: Date = .now) {
        let entries = drafts.compactMap { draft -> WorkoutEntry? in
            guard !draft.sets.isEmpty else { return nil }
            return WorkoutEntry(
                exercise: draft.exercise,
                sets: draft.sets,
                date: date,
                notes: draft.notes
            )
        }
        addWorkouts(entries)
    }

    func addWeight(_ entry: WeightEntry, skipHealthSync: Bool = false) {
        context.insert(WeightRecord(from: entry))
        saveAndReload()
        if !skipHealthSync {
            syncToHealthIfNeeded { await $0.syncWeight(entry) }
        }
        syncToFirestoreIfNeeded { try await $0.saveWeight(entry) }
    }

    /// Keeps the Home weight tile and Progress log aligned with the profile weight the user set.
    func syncProfileBodyWeight(_ profile: UserProfile) {
        let lbs = SyncFitFormat.round(profile.bodyWeightLbs)
        guard lbs > 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        if let existing = weights.first(where: { calendar.isDate($0.date, inSameDayAs: today) }) {
            var updated = existing
            updated.weight = lbs
            updated.date = today
            updateWeight(updated)
        } else {
            addWeight(WeightEntry(weight: lbs, date: today), skipHealthSync: true)
        }
    }

    func updateWeight(_ entry: WeightEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<WeightRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        record.weight = entry.weight
        record.date = entry.date
        saveAndReload()
        syncToHealthIfNeeded { await $0.syncWeight(entry) }
        syncToFirestoreIfNeeded { try await $0.saveWeight(entry) }
    }

    func deleteWeight(_ entry: WeightEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<WeightRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        context.delete(record)
        saveAndReload()
        syncToFirestoreIfNeeded { try await $0.deleteWeight(entry) }
    }

    func progressPhotos(for userId: String? = nil) -> [ProgressPhotoEntry] {
        let resolvedUserId = userId ?? ProgressPhotoStorage.localUserId
        return progressPhotos.filter { $0.userId == resolvedUserId }
    }

    func addProgressPhoto(_ image: UIImage, date: Date = .now, userId: String? = nil) throws {
        let resolvedUserId = userId ?? ProgressPhotoStorage.localUserId
        let id = UUID()
        let fileName = try ProgressPhotoStorage.saveJPEG(from: image, id: id, userId: resolvedUserId)
        let entry = ProgressPhotoEntry(
            id: id,
            date: Calendar.current.startOfDay(for: date),
            fileName: fileName,
            userId: resolvedUserId
        )
        context.insert(ProgressPhotoRecord(from: entry))
        saveAndReload()
    }

    func deleteProgressPhoto(_ entry: ProgressPhotoEntry) {
        let targetID = entry.id
        var descriptor = FetchDescriptor<ProgressPhotoRecord>(
            predicate: #Predicate { $0.id == targetID }
        )
        guard let record = try? context.fetch(descriptor).first else { return }
        ProgressPhotoStorage.delete(fileName: record.fileName, userId: record.userId)
        context.delete(record)
        saveAndReload()
    }


    /// Merge cloud progress-photo metadata into local SwiftData (keeps local image cache).
    func mergeCloudProgressPhotos(_ cloudPhotos: [ProgressPhotoEntry]) {
        guard !cloudPhotos.isEmpty else { return }
        var changed = false
        for cloud in cloudPhotos {
            let targetID = cloud.id
            var descriptor = FetchDescriptor<ProgressPhotoRecord>(
                predicate: #Predicate { $0.id == targetID }
            )
            if let existing = try? context.fetch(descriptor).first {
                if existing.userId != cloud.userId {
                    existing.userId = cloud.userId
                    changed = true
                }
            } else {
                context.insert(ProgressPhotoRecord(from: cloud))
                changed = true
            }
        }
        if changed {
            saveAndReload()
        }
    }

    private func saveAndReload() {
        try? context.save()
        reload()
    }

    private func syncToHealthIfNeeded(_ operation: @escaping (HealthKitService) async -> Void) {
        guard isHealthSyncEnabled(), let healthKit, healthKit.connectionStatus == .connected else { return }
        Task { await operation(healthKit) }
    }

    private func syncToFirestoreIfNeeded(
        label: String = "firestore",
        _ operation: @escaping (FirestoreDatabaseManager) async throws -> Void
    ) {
        guard let firestore else {
            print("[WorkoutSync] \(label) skipped — Firestore unavailable")
            return
        }
        Task {
            do {
                try await operation(firestore)
                print("[WorkoutSync] \(label) succeeded")
            } catch {
                // Never swallow — silent try? hid permission / write failures.
                print("[WorkoutSync] \(label) FAILED: \(error)")
            }
        }
    }

    /// After cloud history replace, rebuild empty scheduled days from routines
    /// referenced by customRoutineID so Custom labels aren't blank.
    func rehydrateScheduledDayPlansIfNeeded() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let assignment = scheduledAssignment(for: date)
            guard assignment.kind != .unassigned, assignment.kind != .rest else { continue }

            if let slotID = assignment.customRoutineID {
                let localMatch = routines.first(where: { $0.id == slotID })
                print("[WorkoutSync] ID check day=\(Self.dayKey(for: date)) schedule.customRoutineID=\(slotID.uuidString) localRoutineFound=\(localMatch != nil) localExerciseCount=\(localMatch?.exercises.count ?? -1)")
            }

            guard let routine = scheduledRoutine(for: date) else {
                print("[WorkoutSync] Rehydrate skipped — schedule points at missing routineID=\(assignment.customRoutineID?.uuidString ?? "nil") kind=\(assignment.kind.rawValue)")
                continue
            }
            if workouts(on: date).isEmpty {
                print("[WorkoutSync] Rehydrating empty day \(Self.dayKey(for: date)) from routineID=\(routine.id.uuidString) name=\(routine.name) exercises=\(routine.exercises.count)")
                applyRoutineToDay(routine, on: date)
            }
        }
        objectWillChange.send()
    }

    /// Push any local routines that the schedule references but may not be in Firestore yet.
    func syncReferencedRoutinesToCloudIfNeeded() {
        var ids = Set(weekSchedule.days.compactMap(\.customRoutineID))
        ids.formUnion(dayTemplateRoutineIDs.values)
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let routine = routines.first(where: { $0.id == id }) else {
                print("[WorkoutSync] Schedule references missing local routineID=\(id.uuidString)")
                continue
            }
            print("[WorkoutSync] Backfilling routine content id=\(routine.id.uuidString) exercises=\(routine.exercises.count)")
            syncToFirestoreIfNeeded(label: "saveRoutine.backfill") { try await $0.saveRoutine(routine) }
        }
    }

    private func syncDayWorkoutIfNeeded(on date: Date) {
        syncToHealthIfNeeded { await $0.syncDayWorkout(on: date, dataStore: self) }
    }

    private func fetchWorkouts() -> [WorkoutEntry] {
        var descriptor = FetchDescriptor<WorkoutRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        let calendar = Calendar.current
        return records.map { record in
            var entry = record.asEntry
            entry.date = calendar.startOfDay(for: entry.date)
            return entry
        }
    }

    private func fetchFoods() -> [FoodEntry] {
        var descriptor = FetchDescriptor<FoodRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        let calendar = Calendar.current
        return records.map { record in
            var entry = record.asEntry
            entry.date = calendar.startOfDay(for: entry.date)
            return entry
        }
    }

    private func fetchWeights() -> [WeightEntry] {
        var descriptor = FetchDescriptor<WeightRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map(\.asEntry)
    }

    private func fetchProgressPhotos() -> [ProgressPhotoEntry] {
        var descriptor = FetchDescriptor<ProgressPhotoRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map(\.asEntry)
    }

    private func fetchCoaches() -> [CoachProfile] {
        var descriptor = FetchDescriptor<CoachRecord>(
            sortBy: [SortDescriptor(\.name)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map(\.asProfile)
    }

    private func fetchExercises() -> [Exercise] {
        var descriptor = FetchDescriptor<ExerciseRecord>(
            sortBy: [SortDescriptor(\.muscleGroup), SortDescriptor(\.name)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map(\.asExercise)
    }

    private func fetchSavedMeals() -> [SavedMeal] {
        var descriptor = FetchDescriptor<SavedMealRecord>(
            sortBy: [SortDescriptor(\.name)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map(\.asSavedMeal)
    }

    private func fetchRoutines() -> [WorkoutRoutine] {
        var descriptor = FetchDescriptor<WorkoutRoutineRecord>(
            sortBy: [SortDescriptor(\.name)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map { fetchRoutine(for: $0) }
    }

    private func fetchRoutine(for record: WorkoutRoutineRecord) -> WorkoutRoutine {
        let routineID = record.id
        var exerciseDescriptor = FetchDescriptor<RoutineExerciseRecord>(
            predicate: #Predicate { $0.routineID == routineID },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let items = ((try? context.fetch(exerciseDescriptor)) ?? []).map(\.asItem)
        return WorkoutRoutine(id: record.id, name: record.name, exercises: items)
    }

    private func migrateRoutineExerciseOwnership() {
        let allExercises = (try? context.fetch(FetchDescriptor<RoutineExerciseRecord>())) ?? []
        let allRoutines = (try? context.fetch(FetchDescriptor<WorkoutRoutineRecord>())) ?? []
        let routineIDs = Set(allRoutines.map(\.id))
        var changed = false

        for exercise in allExercises {
            if exercise.needsRoutineIDBackfill || !routineIDs.contains(exercise.routineID),
               let owner = exercise.routine {
                exercise.routineID = owner.id
                changed = true
            } else if let owner = exercise.routine, exercise.routineID != owner.id {
                exercise.routineID = owner.id
                changed = true
            }

            if exercise.plannedSetCount <= 0,
               let legacy = RoutineExerciseRecord.decodePlannedSets(from: exercise.plannedSetsJSON),
               !legacy.isEmpty {
                exercise.plannedSetCount = legacy.count
                exercise.plannedReps = legacy[0].reps
                exercise.plannedWeight = legacy[0].weight
                changed = true
            }
        }

        for routine in allRoutines {
            let owned = routine.exercises.filter { $0.routineID == routine.id }
            if owned.count != routine.exercises.count {
                routine.exercises = owned
                changed = true
            }
            for exercise in owned where exercise.routine?.id != routine.id {
                exercise.routine = routine
                changed = true
            }
        }

        for exercise in allExercises
        where exercise.needsRoutineIDBackfill || (!routineIDs.contains(exercise.routineID) && exercise.routine == nil) {
            context.delete(exercise)
            changed = true
        }

        if changed {
            try? context.save()
        }
    }

    static func preview() -> FitnessDataStore {
        let container = try! SyncFitModelContainer.make(inMemory: true)
        let context = container.mainContext
        SampleDataSeeder.seedIfNeeded(context: context)
        return FitnessDataStore(context: context)
    }
}

enum SampleData {
    static let workouts: [WorkoutEntry] = [
        WorkoutEntry(
            exercise: Exercise(name: "Bench Press", muscleGroup: "Chest"),
            sets: [
                WorkoutSet(reps: 8, weight: 135),
                WorkoutSet(reps: 8, weight: 145),
                WorkoutSet(reps: 6, weight: 155)
            ],
            date: .now,
            notes: "Felt strong today"
        ),
        WorkoutEntry(
            exercise: Exercise(name: "Squat", muscleGroup: "Legs"),
            sets: [
                WorkoutSet(reps: 5, weight: 185),
                WorkoutSet(reps: 5, weight: 205),
                WorkoutSet(reps: 5, weight: 225)
            ],
            date: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        )
    ]

    static let foods: [FoodEntry] = [
        FoodEntry(name: "Greek Yogurt & Berries", calories: 320, protein: 28, carbs: 35, fat: 8, meal: .breakfast),
        FoodEntry(name: "Chicken Rice Bowl", calories: 580, protein: 45, carbs: 62, fat: 12, meal: .lunch),
        FoodEntry(name: "Protein Shake", calories: 220, protein: 40, carbs: 8, fat: 3, meal: .snack)
    ]

    static let weights: [WeightEntry] = [
        WeightEntry(weight: 178.2),
        WeightEntry(weight: 178.8, date: Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now),
        WeightEntry(weight: 179.5, date: Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now)
    ]

    static let coaches: [CoachProfile] = [
        CoachProfile(
            name: "Alex Rivera",
            specialty: "Muscle building",
            pricePerMonth: 75,
            isOnline: true,
            rating: 4.9,
            bio: "8 years coaching natural lifters. Focus on progressive overload and sustainable nutrition. I help clients build muscle without burnout.",
            clientCount: 47,
            reviewCount: 38,
            availability: .online,
            specialties: ["Muscle building", "Hypertrophy", "Strength"],
            reviews: [
                CoachReview(clientName: "Marcus T.", text: "Alex helped me add 12 lbs of muscle in 6 months. Programming is dialed.", rating: 5),
                CoachReview(clientName: "Sarah K.", text: "Clear check-ins and adjustments every week. Worth every penny.", rating: 5),
                CoachReview(clientName: "Dev P.", text: "Best coach I've worked with online. Responds fast and knows his stuff.", rating: 4.8)
            ]
        ),
        CoachProfile(
            name: "Jordan Lee",
            specialty: "Fat loss",
            pricePerMonth: 120,
            isOnline: true,
            rating: 4.8,
            bio: "Helps busy professionals lose fat without extreme diets. Sustainable habits, real results.",
            clientCount: 31,
            reviewCount: 24,
            availability: .online,
            specialties: ["Fat loss", "Weight loss", "Nutrition"],
            reviews: [
                CoachReview(clientName: "Emily R.", text: "Down 22 lbs in 4 months without feeling miserable. Jordan gets it.", rating: 5),
                CoachReview(clientName: "Chris M.", text: "Accountability and meal guidance made all the difference.", rating: 4.7),
                CoachReview(clientName: "Nina L.", text: "Finally found a coach who doesn't push crash diets.", rating: 4.9)
            ]
        ),
        CoachProfile(
            name: "Sam Patel",
            specialty: "Powerlifting",
            pricePerMonth: 150,
            isOnline: false,
            rating: 5.0,
            bio: "In-person coaching in Austin, TX. Specializes in squat, bench, and deadlift for competitive and recreational lifters.",
            clientCount: 22,
            reviewCount: 18,
            availability: .inPerson,
            location: "Austin, TX",
            specialties: ["Powerlifting", "Strength", "Competition prep"],
            reviews: [
                CoachReview(clientName: "Jake W.", text: "Added 80 lbs to my total in one meet prep cycle.", rating: 5),
                CoachReview(clientName: "Amy C.", text: "Sam's cueing and technique work are elite.", rating: 5),
                CoachReview(clientName: "Tom H.", text: "Best powerlifting coach in Austin, hands down.", rating: 5)
            ]
        )
    ]
}
