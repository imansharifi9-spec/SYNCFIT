import Foundation

struct AIInsight: Identifiable {
    let id = UUID()
    let category: String
    let icon: String
    let message: String
    let secondaryMessage: String?
    let callToAction: String
    let action: WorkoutInsightAction

    /// One-line teaser for the workout screen AI strip.
    var stripSummary: String {
        let compact = message
            .replacingOccurrences(of: "You're ", with: "")
            .replacingOccurrences(of: "you're ", with: "")
        return "AI: \(compact)"
    }

    init(
        category: String,
        icon: String,
        message: String,
        secondaryMessage: String? = nil,
        callToAction: String = "View AI Plan",
        action: WorkoutInsightAction = .viewPlan
    ) {
        self.category = category
        self.icon = icon
        self.message = message
        self.secondaryMessage = secondaryMessage
        self.callToAction = callToAction
        self.action = action
    }
}

enum WorkoutInsightAction {
    case viewPlan
}

@MainActor
enum AIInsightService {
    static func dailyInsights(profile: UserProfile, dataStore: FitnessDataStore, limit: Int = 2) -> [AIInsight] {
        var insights: [(priority: Int, insight: AIInsight)] = []

        if let recovery = recoveryInsight(dataStore: dataStore) {
            insights.append((10, recovery))
        }
        if let pace = goalPaceInsight(profile: profile, dataStore: dataStore) {
            insights.append((9, pace))
        }
        if let protein = proteinPaceInsight(profile: profile, dataStore: dataStore) {
            insights.append((8, protein))
        }
        if let strength = strengthInsight(dataStore: dataStore) {
            insights.append((7, strength))
        }
        if let weight = weightTrendInsight(profile: profile, dataStore: dataStore) {
            insights.append((6, weight))
        }

        if insights.isEmpty {
            insights.append((0, AIInsight(
                category: "Getting Started",
                icon: "sparkles",
                message: "Log a workout and a meal today — SyncFit+ will turn your data into daily strength, recovery, and goal insights."
            )))
        }

        return insights
            .sorted { $0.priority > $1.priority }
            .prefix(limit)
            .map(\.insight)
    }

    static func workoutPageSuggestion(profile: UserProfile, dataStore: FitnessDataStore) -> AIInsight {
        if isTodaysWorkoutComplete(dataStore: dataStore) {
            return postWorkoutNutritionInsight(profile: profile, dataStore: dataStore)
        }

        let candidates = workoutPageInsights(profile: profile, dataStore: dataStore)
        guard !candidates.isEmpty else {
            return AIInsight(
                category: "Workout",
                icon: "bolt.fill",
                message: "SyncFit+ builds today's session around your goal, experience, and recovery.",
                secondaryMessage: "Get warm-ups, working sets, and accessories tailored to your plan."
            )
        }
        let dayIndex = Calendar.current.ordinality(of: .day, in: .year, for: .now) ?? 0
        return candidates[dayIndex % candidates.count]
    }

    private static func workoutPageInsights(profile: UserProfile, dataStore: FitnessDataStore) -> [AIInsight] {
        var insights: [AIInsight] = []

        let proteinGap = max(profile.proteinTarget - dataStore.todaysProtein, 0)
        if proteinGap > 0 {
            insights.append(AIInsight(
                category: "Nutrition",
                icon: "fork.knife",
                message: "You're \(proteinGap)g protein short today.",
                secondaryMessage: "SyncFit+ builds meal suggestions to close the gap without overshooting calories."
            ))
        }

        if let routine = dataStore.routine(for: .now),
           routine.sortedExercises.contains(where: {
               $0.exercise.name.localizedCaseInsensitiveContains("bench")
           }) {
            insights.append(AIInsight(
                category: "Workout",
                icon: "dumbbell.fill",
                message: "Bench Press is on today's plan.",
                secondaryMessage: "SyncFit+ suggests when to add load, hold steady, or swap accessories."
            ))
        }

        if let routine = dataStore.routine(for: .now) {
            let sessionKeyword = dataStore.sessionName(for: .now) ?? routine.name
            let hits = dataStore.sessionCountThisWeek(matching: sessionKeyword)
            if hits >= 2 {
                insights.append(AIInsight(
                    category: "Progress",
                    icon: "chart.line.uptrend.xyaxis",
                    message: "You've completed \(sessionKeyword) twice this week.",
                    secondaryMessage: "SyncFit+ adjusts volume and intensity when you're repeating sessions."
                ))
            }

            let weeks = dataStore.consecutiveWeeksTrainingSession(matching: sessionKeyword)
            if weeks >= 2 {
                insights.append(AIInsight(
                    category: "Progress",
                    icon: "flame.fill",
                    message: "You've completed \(sessionKeyword) \(weeks) weeks in a row.",
                    secondaryMessage: "SyncFit+ tracks streaks and suggests deloads before fatigue builds."
                ))
            }
        }

        if !dataStore.hasWorkoutToday, let routine = dataStore.routine(for: .now) {
            let keyword = dataStore.sessionName(for: .now) ?? routine.name
            let groups = Array(Set(routine.sortedExercises.map(\.exercise.muscleGroup))).sorted()
            let focus = groups.isEmpty ? "your scheduled muscles" : groups.joined(separator: ", ")
            insights.append(AIInsight(
                category: "Workout",
                icon: "bolt.fill",
                message: "Today's \(keyword) session targets \(focus).",
                secondaryMessage: "SyncFit+ builds your warm-up, working sets, and accessories."
            ))
        }

        return insights
    }

    private static func isTodaysWorkoutComplete(dataStore: FitnessDataStore) -> Bool {
        if let routine = dataStore.routine(for: .now) {
            let progress = dataStore.scheduledRoutineProgress(for: .now, routine: routine)
            if progress.total > 0 {
                return progress.completed >= progress.total
            }
        }
        return dataStore.hasWorkoutToday
    }

    private static func postWorkoutNutritionInsight(
        profile: UserProfile,
        dataStore: FitnessDataStore
    ) -> AIInsight {
        let proteinGap = max(profile.proteinTarget - dataStore.todaysProtein, 0)
        let mealLow = min(40, max(25, proteinGap / 3))
        let mealHigh = min(55, max(mealLow + 10, proteinGap / 2))

        return AIInsight(
            category: "Nutrition",
            icon: "fork.knife",
            message: "You're \(proteinGap)g protein short today.",
            secondaryMessage: "Based on today's workout, aim for \(mealLow)–\(mealHigh)g protein in your next meal."
        )
    }

    private static func recoveryInsight(dataStore: FitnessDataStore) -> AIInsight? {
        let streak = consecutiveTrainingDays(dataStore: dataStore)
        if streak >= 2 {
            return AIInsight(
                category: "Recovery",
                icon: "bed.double.fill",
                message: "You've trained \(streak) days in a row. Lighter accessory work or active recovery today can protect strength gains and reduce fatigue."
            )
        }

        let daysSinceWorkout = daysSinceLastWorkout(dataStore: dataStore)
        if daysSinceWorkout >= 3 {
            return AIInsight(
                category: "Recovery",
                icon: "figure.walk",
                message: "It's been \(daysSinceWorkout) days since your last session. A moderate workout today can restart momentum without overreaching."
            )
        }
        return nil
    }

    private static func goalPaceInsight(profile: UserProfile, dataStore: FitnessDataStore) -> AIInsight? {
        let proteinTarget = max(profile.proteinTarget, 1)
        let proteinProgress = min(Double(dataStore.todaysProtein) / Double(proteinTarget), 1)
        let workoutProgress = dataStore.hasWorkoutToday ? 1.0 : 0.0
        let mission = (proteinProgress + workoutProgress) / 2
        let percent = Int((mission * 100).rounded())

        if mission >= 1 {
            return AIInsight(
                category: "Goal Pace",
                icon: "flag.checkered",
                message: "You're 100% through today's mission. SyncFit+ tracks this pace weekly so you know if you're ahead or behind your \(profile.goal.rawValue.lowercased()) target."
            )
        }

        var missing: [String] = []
        if dataStore.todaysProtein < proteinTarget {
            missing.append("protein")
        }
        if !dataStore.hasWorkoutToday {
            missing.append("today's workout")
        }

        let missingText = missing.joined(separator: " and ")
        return AIInsight(
            category: "Goal Pace",
            icon: "chart.line.uptrend.xyaxis",
            message: "You're \(percent)% through today's mission. Finish \(missingText) to stay on pace for your \(profile.goal.rawValue.lowercased()) goal."
        )
    }

    private static func proteinPaceInsight(profile: UserProfile, dataStore: FitnessDataStore) -> AIInsight? {
        let target = profile.proteinTarget
        let current = dataStore.todaysProtein
        guard current < target else { return nil }

        let hour = max(Calendar.current.component(.hour, from: .now), 1)
        let gap = target - current

        if current == 0 && hour >= 14 {
            return AIInsight(
                category: "Nutrition Pace",
                icon: "fork.knife",
                message: "No protein logged yet today. SyncFit+ suggests quick adds — like Greek yogurt or a shake — to stay on track for your \(target)g target."
            )
        }

        if current > 0 {
            let hourlyRate = Double(current) / Double(hour)
            if hourlyRate > 0 {
                let hoursRemaining = Int(ceil(Double(gap) / hourlyRate))
                let etaHour = min(hour + hoursRemaining, 23)
                let etaText = etaHour <= hour ? "later today" : "around \(formattedHour(etaHour))"
                return AIInsight(
                    category: "Nutrition Pace",
                    icon: "bolt.fill",
                    message: "At \(current)g by \(formattedHour(hour)), you're on track to hit \(target)g \(etaText). You need \(gap)g more."
                )
            }
        }

        return AIInsight(
            category: "Nutrition Pace",
            icon: "bolt.fill",
            message: "You need \(gap)g more protein today. SyncFit+ builds meal suggestions to close the gap without overshooting calories."
        )
    }

    private static func strengthInsight(dataStore: FitnessDataStore) -> AIInsight? {
        let calendar = Calendar.current
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
        let lastWeekEnd = thisWeekStart

        let thisWeek = dataStore.workouts.filter { $0.date >= thisWeekStart }.count
        let lastWeek = dataStore.workouts.filter { $0.date >= lastWeekStart && $0.date < lastWeekEnd }.count

        guard thisWeek > 0 || lastWeek > 0 else { return nil }

        if thisWeek > lastWeek {
            return AIInsight(
                category: "Strength",
                icon: "dumbbell.fill",
                message: "\(thisWeek) workouts this week vs \(lastWeek) last week — volume is trending up. SyncFit+ flags when to push load vs hold steady."
            )
        }

        if thisWeek < lastWeek && lastWeek > 0 {
            return AIInsight(
                category: "Strength",
                icon: "dumbbell.fill",
                message: "\(thisWeek) workouts so far this week vs \(lastWeek) last week. SyncFit+ helps you adjust volume to keep progressing toward strength goals."
            )
        }

        return AIInsight(
            category: "Strength",
            icon: "dumbbell.fill",
            message: "You're matching last week's training volume. SyncFit+ analyzes your sets and suggests when to add weight or reps."
        )
    }

    private static func weightTrendInsight(profile: UserProfile, dataStore: FitnessDataStore) -> AIInsight? {
        guard let deltaLbs = dataStore.weeklyWeightDelta() else { return nil }

        let isMetric = profile.measurementSystem == .metric
        let magnitude = isMetric ? abs(deltaLbs) * 0.453592 : abs(deltaLbs)
        let unit = isMetric ? "kg" : "lb"

        if magnitude < 0.05 {
            return AIInsight(
                category: "Body Composition",
                icon: "scalemass.fill",
                message: "Weight held steady this week. SyncFit+ ties scale trends to nutrition and training so you know what's working."
            )
        }

        let direction = deltaLbs > 0 ? "up" : "down"
        let goalContext: String
        switch profile.goal {
        case .loseFat:
            goalContext = deltaLbs < 0 ? " — aligned with your fat loss goal." : " — SyncFit+ can help tighten nutrition to get back on track."
        case .buildMuscle:
            goalContext = deltaLbs > 0 ? " — monitor that gain stays lean with your protein target." : " — consider a slight calorie bump to support muscle growth."
        default:
            goalContext = "."
        }

        return AIInsight(
            category: "Body Composition",
            icon: "scalemass.fill",
            message: "You're \(direction) \(String(format: "%.1f", magnitude)) \(unit) this week\(goalContext)"
        )
    }

    private static func consecutiveTrainingDays(dataStore: FitnessDataStore) -> Int {
        let calendar = Calendar.current
        var count = 0
        var day = calendar.startOfDay(for: .now)

        while true {
            let range = DayHistory.dateRange(for: day, calendar: calendar)
            if dataStore.workouts(in: range).isEmpty { break }
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    private static func daysSinceLastWorkout(dataStore: FitnessDataStore) -> Int {
        guard let latest = dataStore.workouts.first else { return 99 }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: latest.date)
        let today = calendar.startOfDay(for: .now)
        return calendar.dateComponents([.day], from: start, to: today).day ?? 0
    }

    private static func formattedHour(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        var components = DateComponents()
        components.hour = normalized
        let date = Calendar.current.date(from: components) ?? .now
        return formatter.string(from: date)
    }
}
