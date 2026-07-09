import Foundation

/// Shared max-weight logic for strength charts, captions, and PRs.
/// Always reads **logged** `sets[].weight` — never `plannedSets`, never `reps`.
enum ExerciseMaxWeight {
    /// All logged set weights for `exerciseName` across the given entries (flattened).
    static func loggedSetWeights(for exerciseName: String, in entries: [WorkoutEntry]) -> [Double] {
        entries
            .filter { $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame }
            .flatMap(\.sets)
            .map(\.weight)
            .filter { $0 > 0 }
    }

    /// Highest single-set weight logged for `exerciseName` across entries.
    static func maxLoggedWeight(for exerciseName: String, in entries: [WorkoutEntry]) -> Double? {
        loggedSetWeights(for: exerciseName, in: entries).max()
    }

    /// Max weight logged for `exerciseName` in a single workout entry.
    static func maxWeight(for exerciseName: String, in entry: WorkoutEntry) -> Double? {
        maxLoggedWeight(for: exerciseName, in: [entry])
    }

    /// Max weight across all logged sets for this exercise on the same calendar day (one session).
    static func maxWeight(
        for exerciseName: String,
        on day: Date,
        in entries: [WorkoutEntry],
        calendar: Calendar = .current
    ) -> Double? {
        let dayEntries = entries.filter {
            calendar.isDate($0.date, inSameDayAs: day)
                && $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame
        }
        return maxLoggedWeight(for: exerciseName, in: dayEntries)
    }

    /// One max per session day, sorted oldest → newest.
    static func sessionMaxWeights(
        for exerciseName: String,
        in workouts: [WorkoutEntry],
        within interval: DateInterval? = nil,
        calendar: Calendar = .current
    ) -> [(date: Date, weight: Double)] {
        var matching = workouts.filter {
            $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame
                && !$0.sets.isEmpty
        }
        if let interval {
            matching = matching.filter { $0.date >= interval.start && $0.date < interval.end }
        }

        let grouped = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.date) }
        return grouped.compactMap { day, dayEntries -> (date: Date, weight: Double)? in
            guard let max = maxLoggedWeight(for: exerciseName, in: dayEntries), max > 0 else {
                return nil
            }
            let sessionDate = dayEntries.map(\.date).max() ?? day
            return (sessionDate, max)
        }
        .sorted { $0.date < $1.date }
    }

    /// All-time highest single-set weight for an exercise.
    static func allTimeMax(
        for exerciseName: String,
        in workouts: [WorkoutEntry]
    ) -> (weight: Double, date: Date)? {
        var best: (weight: Double, date: Date)?
        for entry in workouts.sorted(by: { $0.date < $1.date }) {
            guard let max = maxWeight(for: exerciseName, in: entry) else { continue }
            if let current = best {
                if max > current.weight {
                    best = (max, entry.date)
                }
            } else {
                best = (max, entry.date)
            }
        }
        return best
    }

    /// Max weight from the chronologically first session for this exercise.
    static func firstSessionMax(
        for exerciseName: String,
        in workouts: [WorkoutEntry],
        calendar: Calendar = .current
    ) -> Double? {
        sessionMaxWeights(for: exerciseName, in: workouts, calendar: calendar).first?.weight
    }
}
