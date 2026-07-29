import Foundation
import SwiftData

enum SampleDataSeeder {
    static func seedIfNeeded(context: ModelContext) {
        seedExercisesIfNeeded(context: context)
        seedDemoContentIfNeeded(context: context)
        migrateCoachClientCountsIfNeeded(context: context)
    }

    private static func seedExercisesIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<ExerciseRecord>()
        let existing = (try? context.fetch(descriptor)) ?? []

        if existing.isEmpty {
            for exercise in ExerciseLibrary.exercises {
                context.insert(ExerciseRecord(from: exercise))
            }
            try? context.save()
            return
        }

        // Upsert catalog expansions onto installs that already seeded an older library.
        let existingNames = Set(existing.map { $0.name.lowercased() })
        var inserted = 0
        for exercise in ExerciseLibrary.exercises where !existingNames.contains(exercise.name.lowercased()) {
            context.insert(ExerciseRecord(from: exercise))
            inserted += 1
        }
        if inserted > 0 {
            try? context.save()
        }
    }

    private static func seedDemoContentIfNeeded(context: ModelContext) {
        let coachDescriptor = FetchDescriptor<CoachRecord>()
        let existingCoaches = (try? context.fetch(coachDescriptor)) ?? []
        guard existingCoaches.isEmpty else { return }

        for coach in SampleData.coaches {
            context.insert(CoachRecord(from: coach))
        }

        try? context.save()
    }

    private static func migrateCoachClientCountsIfNeeded(context: ModelContext) {
        let expectedCounts = [
            "Alex Rivera": 47,
            "Jordan Lee": 31,
            "Sam Patel": 22
        ]
        let records = (try? context.fetch(FetchDescriptor<CoachRecord>())) ?? []
        var changed = false

        for record in records {
            guard let expected = expectedCounts[record.name], record.clientCount == 0 else { continue }
            record.clientCount = expected
            changed = true
        }

        if changed {
            try? context.save()
        }
    }
}
