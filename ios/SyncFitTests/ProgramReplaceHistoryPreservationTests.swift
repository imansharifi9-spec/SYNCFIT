import XCTest
import SwiftData
@testable import SyncFit

@MainActor
final class ProgramReplaceHistoryPreservationTests: XCTestCase {
    func testImportProgramTemplatePreservesLoggedHistoryAndClearsEmptyPlans() throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let store = FitnessDataStore(context: container.mainContext)

        let calendar = Calendar.current
        let historyDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -10, to: .now) ?? .now
        )
        let planDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -3, to: .now) ?? .now
        )

        let loggedHistory = WorkoutEntry(
            id: UUID(),
            exercise: Exercise(name: "Barbell Back Squat", muscleGroup: "Legs"),
            sets: [
                WorkoutSet(reps: 5, weight: 225),
                WorkoutSet(reps: 5, weight: 235)
            ],
            plannedSets: [
                WorkoutSet(reps: 5, weight: 225)
            ],
            date: historyDate,
            notes: ""
        )

        let emptyPlan = WorkoutEntry(
            id: UUID(),
            exercise: Exercise(name: "Bench Press", muscleGroup: "Chest"),
            sets: [],
            plannedSets: [
                WorkoutSet(reps: 8, weight: 135),
                WorkoutSet(reps: 8, weight: 135)
            ],
            date: planDate,
            notes: ""
        )

        store.addWorkout(loggedHistory)
        store.addWorkout(emptyPlan)

        store.importProgramTemplate(Self.fullBodyTemplate, replaceExisting: true)

        XCTAssertNotNil(store.workouts.first(where: { $0.id == loggedHistory.id }))
        let preserved = try XCTUnwrap(store.workouts.first(where: { $0.id == loggedHistory.id }))
        XCTAssertEqual(preserved.sets.count, 2)
        XCTAssertNil(store.workouts.first(where: { $0.id == emptyPlan.id }))
    }

    func testImportProgramTemplatePreservesCompletedDaySessionLabel() throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let store = FitnessDataStore(context: container.mainContext)
        let today = Calendar.current.startOfDay(for: .now)
        let todayWeekday = Calendar.current.component(.weekday, from: today)

        store.setSessionLabel("Legs", for: today)
        store.addWorkout(
            WorkoutEntry(
                id: UUID(),
                exercise: Exercise(name: "Romanian Deadlift", muscleGroup: "Legs"),
                sets: [WorkoutSet(reps: 8, weight: 185)],
                plannedSets: [],
                date: today,
                notes: ""
            )
        )
        store.markWorkoutCompleted(for: today)

        store.importProgramTemplate(
            Self.fullBodyTemplate(trainingWeekday: todayWeekday),
            replaceExisting: true
        )

        XCTAssertEqual(store.sessionLabel(for: today), "Legs")
        XCTAssertNotEqual(store.sessionLabel(for: today), "Full Body")
    }

    func testScheduleSwitchKeepsCompletedDayDisplayConsistentAndPlansFutureDays() throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let store = FitnessDataStore(context: container.mainContext)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let tomorrow = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: 1, to: today) ?? today
        )
        let todayWeekday = calendar.component(.weekday, from: today)
        let tomorrowWeekday = calendar.component(.weekday, from: tomorrow)

        // Completed Pull day: 5 logged exercises + frozen session label.
        store.setSessionLabel("Pull", for: today)
        let pullExercises = [
            "Barbell Row",
            "Lat Pulldown",
            "Seated Cable Row",
            "Face Pull",
            "Dumbbell Curl"
        ]
        for name in pullExercises {
            store.addWorkout(
                WorkoutEntry(
                    id: UUID(),
                    exercise: Exercise(name: name, muscleGroup: "Back"),
                    sets: [WorkoutSet(reps: 10, weight: 100)],
                    plannedSets: [],
                    date: today,
                    notes: ""
                )
            )
        }
        store.markWorkoutCompleted(for: today)

        XCTAssertEqual(store.exercisesWithLoggedSetsCount(on: today), 5)

        // Remap today → Legs (8 exercises), tomorrow → Legs (8 exercises).
        store.importProgramTemplate(
            Self.legsTemplate(
                trainingWeekdays: [todayWeekday, tomorrowWeekday],
                exerciseCount: 8
            ),
            replaceExisting: true
        )

        // Home exercise count source
        XCTAssertEqual(
            store.plannedExerciseCount(for: today),
            5,
            "Home count must use logged Pull exercises (5), not new Legs routine (8)"
        )

        // Workouts tab title source (shared helper)
        XCTAssertEqual(
            store.workoutDayDisplayTitle(for: today),
            "Pull",
            "Workouts day hero title must stay frozen as Pull"
        )
        XCTAssertNotEqual(store.workoutDayDisplayTitle(for: today), "Legs")

        // Workouts tab dayWorkouts source — no merged plan rows
        let dayWorkouts = store.workouts(on: today)
        XCTAssertEqual(
            dayWorkouts.count,
            5,
            "dayWorkouts must stay at 5 logged Pull entries (not 13 = 5+8)"
        )
        XCTAssertEqual(dayWorkouts.filter { !$0.sets.isEmpty }.count, 5)
        XCTAssertEqual(
            store.plannedExerciseCount(for: today),
            dayWorkouts.count,
            "Home count and Workouts dayWorkouts.count must agree after the fix"
        )

        // Future/unlogged day still gets the new Legs plan.
        XCTAssertEqual(store.workoutDayDisplayTitle(for: tomorrow), "Legs")
        XCTAssertEqual(store.routineExerciseCount(for: tomorrow), 8)
        XCTAssertEqual(store.plannedExerciseCount(for: tomorrow), 8)
        XCTAssertEqual(
            store.workouts(on: tomorrow).count,
            8,
            "Future Legs day should materialize 8 planned exercise rows"
        )
        XCTAssertTrue(store.workouts(on: tomorrow).allSatisfy { $0.sets.isEmpty })
    }

    func testReloadCleansOrphanedEmptyPlanRowsFromPreFixMergedDays() throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let context = container.mainContext
        let store = FitnessDataStore(context: context)
        let today = Calendar.current.startOfDay(for: .now)

        // Simulate leftover pre-fix merge: 5 logged + 8 empty planned on the same day.
        // Insert orphans via ModelContext so addWorkout → reload doesn't clean them mid-setup.
        for index in 1...5 {
            context.insert(
                WorkoutRecord(
                    from: WorkoutEntry(
                        id: UUID(),
                        exercise: Exercise(name: "Pull \(index)", muscleGroup: "Back"),
                        sets: [WorkoutSet(reps: 8, weight: 100)],
                        plannedSets: [],
                        date: today,
                        notes: ""
                    )
                )
            )
        }
        for index in 1...8 {
            context.insert(
                WorkoutRecord(
                    from: WorkoutEntry(
                        id: UUID(),
                        exercise: Exercise(name: "Legs Plan \(index)", muscleGroup: "Legs"),
                        sets: [],
                        plannedSets: [WorkoutSet(reps: 10, weight: 135)],
                        date: today,
                        notes: ""
                    )
                )
            )
        }
        try context.save()

        let preCleanup = try context.fetch(FetchDescriptor<WorkoutRecord>()).filter {
            Calendar.current.isDate($0.date, inSameDayAs: today)
        }
        XCTAssertEqual(preCleanup.count, 13, "Precondition: simulate 5 logged + 8 empty plan rows")

        store.reload()

        let cleaned = store.workouts(on: today)
        XCTAssertEqual(cleaned.count, 5, "Cleanup must drop empty plan orphans, leaving logged Pull rows")
        XCTAssertEqual(cleaned.filter { !$0.sets.isEmpty }.count, 5)
        XCTAssertTrue(cleaned.allSatisfy { !$0.sets.isEmpty })
    }

    private static let fullBodyTemplate = ProgramTemplate(
        id: "test-full-body",
        name: "Test Full Body",
        description: "Minimal template for history-preservation unit test",
        difficulty: .beginner,
        daysPerWeek: 1,
        goal: .strength,
        days: fullBodyDays(trainingWeekday: 2)
    )

    private static func fullBodyTemplate(trainingWeekday: Int) -> ProgramTemplate {
        ProgramTemplate(
            id: "test-full-body-\(trainingWeekday)",
            name: "Test Full Body",
            description: "Full Body lands on the completed day's weekday",
            difficulty: .beginner,
            daysPerWeek: 1,
            goal: .strength,
            days: fullBodyDays(trainingWeekday: trainingWeekday)
        )
    }

    private static func fullBodyDays(trainingWeekday: Int) -> [ProgramTemplateDaySpec] {
        (1...7).map { weekday in
            if weekday == trainingWeekday {
                return ProgramTemplateDaySpec(
                    weekday: weekday,
                    routineName: "Full Body",
                    exercises: [
                        ProgramTemplateExerciseSpec(name: "Goblet Squat", setCount: 3, reps: 10)
                    ]
                )
            }
            return ProgramTemplateDaySpec(
                weekday: weekday,
                routineName: "Rest",
                exercises: [],
                isRest: true
            )
        }
    }

    private static func legsTemplate(trainingWeekdays: [Int], exerciseCount: Int) -> ProgramTemplate {
        let names = [
            "Back Squat",
            "Romanian Deadlift",
            "Leg Press",
            "Walking Lunge",
            "Leg Curl",
            "Leg Extension",
            "Calf Raise",
            "Hip Thrust",
            "Goblet Squat",
            "Bulgarian Split Squat"
        ]
        let exercises = (0..<exerciseCount).map { index in
            ProgramTemplateExerciseSpec(
                name: names[index % names.count],
                setCount: 3,
                reps: 10
            )
        }
        let training = Set(trainingWeekdays)
        return ProgramTemplate(
            id: "test-legs-\(trainingWeekdays.sorted().map(String.init).joined(separator: "-"))",
            name: "Test Legs",
            description: "Legs mapped onto specific weekdays",
            difficulty: .intermediate,
            daysPerWeek: training.count,
            goal: .hypertrophy,
            days: (1...7).map { weekday in
                if training.contains(weekday) {
                    return ProgramTemplateDaySpec(
                        weekday: weekday,
                        routineName: "Legs",
                        exercises: exercises
                    )
                }
                return ProgramTemplateDaySpec(
                    weekday: weekday,
                    routineName: "Rest",
                    exercises: [],
                    isRest: true
                )
            }
        )
    }
}
