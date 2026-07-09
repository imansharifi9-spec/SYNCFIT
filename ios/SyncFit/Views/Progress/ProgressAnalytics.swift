import Foundation

enum ProgressTimeRange: String, CaseIterable, Identifiable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case all = "All"

    var id: String { rawValue }

    var periodLabel: String {
        switch self {
        case .oneMonth: return "this month"
        case .threeMonths: return "this quarter"
        case .sixMonths: return "this half"
        case .all: return "all time"
        }
    }

    var previousPeriodLabel: String {
        switch self {
        case .oneMonth: return "last month"
        case .threeMonths: return "last quarter"
        case .sixMonths: return "last half"
        case .all: return "prior period"
        }
    }
}

struct ProgressDataSource {
    let userId: String?
    let workouts: [WorkoutEntry]
    let foods: [FoodEntry]
    let weights: [WeightEntry]
    let progressPhotos: [ProgressPhotoEntry]
    let profile: UserProfile

    @MainActor
    static func current(
        dataStore: FitnessDataStore,
        profile: UserProfile,
        userId: String? = nil
    ) -> ProgressDataSource {
        ProgressDataSource(
            userId: userId,
            workouts: dataStore.workouts,
            foods: dataStore.foods,
            weights: dataStore.weights,
            progressPhotos: dataStore.progressPhotos(for: userId),
            profile: profile
        )
    }
}

struct ProgressBodyWeightStat {
    let hasData: Bool
    let valueText: String?
    let deltaText: String?
    let deltaStyle: ProgressDeltaStyle
}

enum ProgressDeltaStyle {
    case positiveGreen
    case negativeRed
    case neutral
}

struct ProgressVolumeStat {
    let hasData: Bool
    let valueText: String?
    let deltaText: String?
    let deltaIsPositive: Bool
}

struct StrengthChartPoint: Identifiable {
    let id = UUID()
    let sessionIndex: Int
    let date: Date
    let maxWeight: Double
    let isMostRecent: Bool
}

struct StrengthChartData {
    let exerciseName: String
    let points: [StrengthChartPoint]
    let startCaption: String?
    let endCaption: String?
    let isEmpty: Bool
    let showsTrendHint: Bool
}

struct ExercisePRRow: Identifiable {
    let id: String
    let exerciseName: String
    let prWeight: Double
    let deltaText: String
    let prDate: Date

    var deltaUsesAccentGreen: Bool {
        deltaText.hasPrefix("↑ +")
    }
}

struct ConsistencyStats {
    let workoutDays: Int
    let proteinGoalDays: Int
    let totalDays: Int
    let workoutDayFlags: [Bool]
    let proteinDayFlags: [Bool]

    init(
        workoutDays: Int,
        proteinGoalDays: Int,
        totalDays: Int,
        workoutDayFlags: [Bool] = [],
        proteinDayFlags: [Bool] = []
    ) {
        self.workoutDays = workoutDays
        self.proteinGoalDays = proteinGoalDays
        self.totalDays = totalDays
        self.workoutDayFlags = workoutDayFlags
        self.proteinDayFlags = proteinDayFlags
    }

    var workoutProgress: Double {
        guard totalDays > 0 else { return 0 }
        return Double(workoutDays) / Double(totalDays)
    }

    var proteinProgress: Double {
        guard totalDays > 0 else { return 0 }
        return Double(proteinGoalDays) / Double(totalDays)
    }
}

enum ProgressAnalytics {
    static func weeksTracked(source: ProgressDataSource, calendar: Calendar = .current) -> Int {
        guard let firstWorkout = source.workouts.map(\.date).min() else { return 0 }
        let start = calendar.startOfDay(for: firstWorkout)
        let today = calendar.startOfDay(for: .now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, (days + 6) / 7)
    }

    static func dateInterval(
        for range: ProgressTimeRange,
        source: ProgressDataSource,
        calendar: Calendar = .current
    ) -> DateInterval {
        let today = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let start: Date
        switch range {
        case .oneMonth:
            start = calendar.date(byAdding: .month, value: -1, to: today) ?? today
        case .threeMonths:
            start = calendar.date(byAdding: .month, value: -3, to: today) ?? today
        case .sixMonths:
            start = calendar.date(byAdding: .month, value: -6, to: today) ?? today
        case .all:
            let earliest = [
                source.workouts.map(\.date).min(),
                source.foods.map(\.date).min(),
                source.weights.map(\.date).min()
            ].compactMap { $0 }.min()
            start = earliest.map { calendar.startOfDay(for: $0) }
                ?? calendar.date(byAdding: .year, value: -1, to: today)
                ?? today
        }
        return DateInterval(start: start, end: end)
    }

    static func previousDateInterval(
        for range: ProgressTimeRange,
        source: ProgressDataSource,
        calendar: Calendar = .current
    ) -> DateInterval {
        let current = dateInterval(for: range, source: source, calendar: calendar)
        let duration = current.duration
        let previousEnd = current.start
        let previousStart = previousEnd.addingTimeInterval(-duration)
        return DateInterval(start: previousStart, end: previousEnd)
    }

    static func bodyWeightStat(
        source: ProgressDataSource,
        range: ProgressTimeRange,
        calendar: Calendar = .current
    ) -> ProgressBodyWeightStat {
        let sorted = source.weights.sorted { $0.date > $1.date }
        guard let latest = sorted.first else {
            return ProgressBodyWeightStat(
                hasData: false,
                valueText: nil,
                deltaText: nil,
                deltaStyle: .neutral
            )
        }

        let interval = dateInterval(for: range, source: source, calendar: calendar)
        let inRange = sorted
            .filter { $0.date >= interval.start && $0.date < interval.end }
            .sorted { $0.date < $1.date }

        let valueText = "\(SyncFitFormat.decimal(latest.weight)) lbs"
        guard let rangeStartWeight = inRange.first?.weight else {
            return ProgressBodyWeightStat(
                hasData: true,
                valueText: valueText,
                deltaText: nil,
                deltaStyle: .neutral
            )
        }

        let delta = latest.weight - rangeStartWeight
        let rounded = Int(delta.rounded())
        guard rounded != 0 else {
            return ProgressBodyWeightStat(
                hasData: true,
                valueText: valueText,
                deltaText: "— no change",
                deltaStyle: .neutral
            )
        }

        let sign = rounded > 0 ? "+" : ""
        let arrow = rounded < 0 ? "↓" : "↑"
        let deltaText = "\(arrow) \(sign)\(rounded) lbs \(range.periodLabel)"
        let deltaStyle = bodyWeightDeltaStyle(delta: delta, goal: source.profile.goal)
        return ProgressBodyWeightStat(
            hasData: true,
            valueText: valueText,
            deltaText: deltaText,
            deltaStyle: deltaStyle
        )
    }

    static func weeklyVolumeStat(
        source: ProgressDataSource,
        range: ProgressTimeRange,
        calendar: Calendar = .current
    ) -> ProgressVolumeStat {
        let interval = dateInterval(for: range, source: source, calendar: calendar)
        let average = averageWeeklyVolume(workouts: source.workouts, in: interval, calendar: calendar)
        guard average > 0 else {
            return ProgressVolumeStat(hasData: false, valueText: nil, deltaText: nil, deltaIsPositive: true)
        }

        let previous = previousDateInterval(for: range, source: source, calendar: calendar)
        let previousAverage = averageWeeklyVolume(workouts: source.workouts, in: previous, calendar: calendar)
        let valueText = formattedVolume(average)

        var deltaText: String?
        var deltaIsPositive = true
        if previousAverage > 0 {
            let pct = Int(((average - previousAverage) / previousAverage * 100).rounded())
            if pct == 0 {
                deltaText = "— no change"
            } else {
                let arrow = pct > 0 ? "↑" : "↓"
                let sign = pct > 0 ? "+" : "−"
                deltaText = "\(arrow) \(sign)\(abs(pct))% vs \(range.previousPeriodLabel)"
                deltaIsPositive = pct > 0
            }
        } else {
            deltaText = "—"
        }

        return ProgressVolumeStat(
            hasData: true,
            valueText: valueText,
            deltaText: deltaText,
            deltaIsPositive: deltaIsPositive
        )
    }

    static func loggedExerciseNames(source: ProgressDataSource) -> [String] {
        var counts: [String: Int] = [:]
        for workout in source.workouts where !workout.sets.isEmpty {
            let name = workout.exercise.name
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    static func defaultStrengthExercise(source: ProgressDataSource) -> String? {
        loggedExerciseNames(source: source).first
    }

    static func strengthChart(
        exerciseName: String,
        source: ProgressDataSource,
        range: ProgressTimeRange,
        calendar: Calendar = .current
    ) -> StrengthChartData {
        let interval = dateInterval(for: range, source: source, calendar: calendar)
        var points = ExerciseMaxWeight.sessionMaxWeights(
            for: exerciseName,
            in: source.workouts,
            within: interval,
            calendar: calendar
        )

        guard !points.isEmpty else {
            return StrengthChartData(
                exerciseName: exerciseName,
                points: [],
                startCaption: nil,
                endCaption: nil,
                isEmpty: true,
                showsTrendHint: false
            )
        }

        if points.count > 8 {
            points = bucketByWeek(points, calendar: calendar)
        }

        let display = Array(points.suffix(8))

        #if DEBUG
        logStrengthChartSessions(
            exerciseName: exerciseName,
            sessions: display,
            workouts: source.workouts,
            calendar: calendar
        )
        #endif

        let chartPoints = display.enumerated().map { index, point in
            StrengthChartPoint(
                sessionIndex: index,
                date: point.date,
                maxWeight: point.weight,
                isMostRecent: index == display.count - 1
            )
        }

        let firstWeight = display.first?.weight ?? 0
        let lastWeight = display.last?.weight ?? 0
        let startCaption = startStrengthCaption(
            date: display.first?.date,
            weight: firstWeight,
            range: range,
            calendar: calendar
        )
        let endCaption = endStrengthCaption(weight: lastWeight, startWeight: firstWeight)

        return StrengthChartData(
            exerciseName: exerciseName,
            points: chartPoints,
            startCaption: startCaption,
            endCaption: endCaption,
            isEmpty: false,
            showsTrendHint: display.count < 4
        )
    }

    static func topPersonalRecords(source: ProgressDataSource, limit: Int = 3) -> [ExercisePRRow] {
        allPersonalRecords(source: source)
            .sorted { $0.prWeight > $1.prWeight }
            .prefix(limit)
            .map { $0 }
    }

    static func allPersonalRecords(source: ProgressDataSource, calendar: Calendar = .current) -> [ExercisePRRow] {
        var displayNames: [String] = []
        var seenKeys = Set<String>()
        for entry in source.workouts.sorted(by: { $0.date < $1.date }) {
            let key = entry.exercise.name.lowercased()
            guard seenKeys.insert(key).inserted else { continue }
            displayNames.append(entry.exercise.name)
        }

        return displayNames.compactMap { name in
            guard let allTime = ExerciseMaxWeight.allTimeMax(for: name, in: source.workouts) else {
                return nil
            }
            let firstSession = ExerciseMaxWeight.firstSessionMax(
                for: name,
                in: source.workouts,
                calendar: calendar
            ) ?? allTime.weight
            let gain = Int((allTime.weight - firstSession).rounded())
            let deltaText = gain > 0 ? "↑ +\(gain) lbs" : "First PR"

            return ExercisePRRow(
                id: name,
                exerciseName: name,
                prWeight: allTime.weight,
                deltaText: deltaText,
                prDate: allTime.date
            )
        }
        .sorted { $0.prDate > $1.prDate }
    }

    static func consistencyStats(
        source: ProgressDataSource,
        range: ProgressTimeRange,
        calendar: Calendar = .current
    ) -> ConsistencyStats {
        let interval = dateInterval(for: range, source: source, calendar: calendar)
        let start = calendar.startOfDay(for: interval.start)
        let today = calendar.startOfDay(for: .now)
        let endDay = min(today, calendar.startOfDay(for: interval.end.addingTimeInterval(-1)))
        let dayCount = max(1, (calendar.dateComponents([.day], from: start, to: endDay).day ?? 0) + 1)

        var workoutDays = 0
        var proteinDays = 0
        var workoutFlags: [Bool] = []
        var proteinFlags: [Bool] = []
        let proteinTarget = source.profile.proteinTarget

        for offset in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if day > today { break }

            let dayWorkouts = source.workouts.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let workoutHit = dayWorkouts.contains(where: { !$0.sets.isEmpty })
            workoutFlags.append(workoutHit)
            if workoutHit { workoutDays += 1 }

            if proteinTarget > 0 {
                let protein = source.foods
                    .filter { calendar.isDate($0.date, inSameDayAs: day) }
                    .reduce(0) { $0 + $1.protein }
                let proteinHit = protein >= proteinTarget
                proteinFlags.append(proteinHit)
                if proteinHit { proteinDays += 1 }
            } else {
                proteinFlags.append(false)
            }
        }

        return ConsistencyStats(
            workoutDays: workoutDays,
            proteinGoalDays: proteinDays,
            totalDays: dayCount,
            workoutDayFlags: workoutFlags,
            proteinDayFlags: proteinFlags
        )
    }

    // MARK: - Helpers

    private static func bodyWeightDeltaStyle(delta: Double, goal: FitnessGoal) -> ProgressDeltaStyle {
        let rounded = Int(delta.rounded())
        guard rounded != 0 else { return .neutral }

        switch goal {
        case .loseFat:
            return rounded < 0 ? .positiveGreen : .negativeRed
        case .buildMuscle, .gainStrength:
            return rounded > 0 ? .positiveGreen : .negativeRed
        case .healthyLifestyle:
            return abs(delta) < 3 ? .neutral : (rounded < 0 ? .positiveGreen : .negativeRed)
        }
    }

    private static func averageWeeklyVolume(
        workouts: [WorkoutEntry],
        in interval: DateInterval,
        calendar: Calendar
    ) -> Double {
        let filtered = workouts.filter { $0.date >= interval.start && $0.date < interval.end }
        guard !filtered.isEmpty else { return 0 }

        var weekVolumes: [Date: Double] = [:]
        for workout in filtered {
            let weekStart = startOfWeek(for: workout.date, calendar: calendar)
            let volume = workout.sets.reduce(0) { $0 + ($1.weight * Double($1.reps)) }
            weekVolumes[weekStart, default: 0] += volume
        }

        let total = weekVolumes.values.reduce(0, +)
        return total / Double(max(weekVolumes.count, 1))
    }

    private static func startOfWeek(for date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: day) ?? day
    }

    private static func bucketByWeek(
        _ points: [(date: Date, weight: Double)],
        calendar: Calendar
    ) -> [(date: Date, weight: Double)] {
        let grouped = Dictionary(grouping: points) { startOfWeek(for: $0.date, calendar: calendar) }
        return grouped.map { week, items in
            (week, items.map(\.weight).max() ?? 0)
        }.sorted { $0.date < $1.date }
    }

    private static func formattedVolume(_ lbs: Double) -> String {
        let rounded = Int(lbs.rounded())
        if rounded >= 1_000 {
            let thousands = Double(rounded) / 1000.0
            return "\(SyncFitFormat.decimal(thousands, maxPlaces: 1))k"
        }
        return SyncFitFormat.formattedInteger(rounded)
    }

    private static func shortDateLabel(_ date: Date, calendar: Calendar) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func startStrengthCaption(
        date: Date?,
        weight: Double,
        range: ProgressTimeRange,
        calendar: Calendar
    ) -> String? {
        guard let date, weight > 0 else { return nil }
        if range == .oneMonth {
            let weeks = max(1, calendar.dateComponents([.weekOfYear], from: date, to: .now).weekOfYear ?? 1)
            return "\(weeks) wk\(weeks == 1 ? "" : "s") ago · \(SyncFitFormat.decimal(weight)) lbs"
        }
        return "\(shortDateLabel(date, calendar: calendar)) · \(SyncFitFormat.decimal(weight)) lbs"
    }

    private static func endStrengthCaption(weight: Double, startWeight: Double) -> String? {
        guard weight > 0 else { return nil }
        if startWeight > 0, startWeight != weight {
            let pct = Int(((weight - startWeight) / startWeight * 100).rounded())
            if pct != 0 {
                let arrow = pct > 0 ? "↑" : "↓"
                return "Now · \(SyncFitFormat.decimal(weight)) lbs \(arrow)\(abs(pct))%"
            }
        }
        return "Now · \(SyncFitFormat.decimal(weight)) lbs"
    }

    static func prSetDateLabel(_ date: Date) -> String {
        "Set \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    #if DEBUG
    private static func logStrengthChartSessions(
        exerciseName: String,
        sessions: [(date: Date, weight: Double)],
        workouts: [WorkoutEntry],
        calendar: Calendar
    ) {
        for (index, session) in sessions.enumerated() {
            let day = calendar.startOfDay(for: session.date)
            let dayEntries = workouts.filter {
                calendar.isDate($0.date, inSameDayAs: day)
                    && $0.exercise.name.caseInsensitiveCompare(exerciseName) == .orderedSame
            }
            let rawSets = dayEntries.flatMap(\.sets)
            let weights = rawSets.map(\.weight)
            let computedMax = ExerciseMaxWeight.maxLoggedWeight(for: exerciseName, in: dayEntries) ?? 0
            let reps = rawSets.map(\.reps)
            print(
                "[StrengthChart] \(exerciseName) session \(index + 1) " +
                "date=\(session.date.formatted(date: .abbreviated, time: .omitted)) " +
                "setWeights=\(weights) setReps=\(reps) " +
                "computedMax=\(computedMax) chartWeight=\(session.weight)"
            )
            if index > 0, session.weight < sessions[index - 1].weight {
                print(
                    "[StrengthChart] WARNING: \(exerciseName) decreased " +
                    "\(sessions[index - 1].weight) → \(session.weight) — verify logged sets"
                )
            }
            if abs(computedMax - session.weight) > 0.01 {
                print(
                    "[StrengthChart] WARNING: \(exerciseName) chart weight \(session.weight) " +
                    "≠ computed max \(computedMax)"
                )
            }
        }
    }
    #endif
}
