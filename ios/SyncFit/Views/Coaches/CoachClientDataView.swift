import SwiftUI
import FirebaseFirestore

@MainActor
final class CoachClientDataViewModel: ObservableObject {
    @Published var workouts: [WorkoutEntry] = []
    @Published var meals: [FoodEntry] = []
    @Published var weights: [WeightEntry] = []
    @Published var clientProfile: FirestoreUserProfile = .empty

    private var listeners: [ListenerRegistration] = []

    func startObserving(connection: CoachClientConnection, firestore: FirestoreDatabaseManager) {
        stopObserving()
        let clientUserID = connection.clientUserID

        if let listener = firestore.observeClientProfile(clientUserID: clientUserID, onChange: { [weak self] profile in
            Task { @MainActor in self?.clientProfile = profile }
        }) {
            listeners.append(listener)
        }

        if connection.shareWorkouts,
           let listener = firestore.observeClientWorkouts(clientUserID: clientUserID, onChange: { [weak self] items in
               Task { @MainActor in self?.workouts = items }
           }) {
            listeners.append(listener)
        }

        if connection.shareNutrition,
           let listener = firestore.observeClientMeals(clientUserID: clientUserID, onChange: { [weak self] items in
               Task { @MainActor in self?.meals = items }
           }) {
            listeners.append(listener)
        }

        if connection.shareProgress,
           let listener = firestore.observeClientWeights(clientUserID: clientUserID, onChange: { [weak self] items in
               Task { @MainActor in self?.weights = items }
           }) {
            listeners.append(listener)
        }
    }

    func stopObserving() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    var progressDataSource: ProgressDataSource {
        ProgressDataSource(
            userId: nil,
            workouts: workouts,
            foods: meals,
            weights: weights,
            progressPhotos: [],
            profile: userProfileFromFirestore
        )
    }

    private var userProfileFromFirestore: UserProfile {
        clientProfile.asUserProfile()
    }
}

struct CoachClientDataView: View {
    let connection: CoachClientConnection

    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @StateObject private var viewModel = CoachClientDataViewModel()
    @State private var showingSendRoutine = false

    private var displayName: String {
        let trimmed = connection.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Anonymous" : trimmed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if connection.shareWorkouts {
                    workoutsSection
                } else {
                    lockedSection(kind: "workouts")
                }

                if connection.shareNutrition {
                    nutritionSection
                } else {
                    lockedSection(kind: "nutrition")
                }

                if connection.shareProgress {
                    progressSection
                } else {
                    lockedSection(kind: "progress")
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(CoachUIColor.page)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Send Routine") {
                    showingSendRoutine = true
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CoachUIColor.accent)
            }
        }
        .sheet(isPresented: $showingSendRoutine) {
            CoachSendRoutineSheet(connection: connection)
        }
        .onAppear {
            viewModel.startObserving(connection: connection, firestore: firestore)
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }

    private var workoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Workouts")

            if workoutSessions.isEmpty {
                emptyHint("No workouts logged yet.")
            } else {
                ForEach(workoutSessions) { session in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.exercises) { exercise in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.exercise.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(exercise.setsSummary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(CoachUIColor.muted)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("\(session.date.formatted(date: .abbreviated, time: .omitted)) · \(Int(session.totalVolume)) lb volume")
                                .font(.system(size: 11))
                                .foregroundStyle(CoachUIColor.muted)
                        }
                    }
                    .padding(12)
                    .background(CoachUIColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var nutritionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Nutrition")

            if dailyNutrition.isEmpty {
                emptyHint("No nutrition logged yet.")
            } else {
                CoachClientNutritionChart(days: dailyNutrition)
                    .padding(12)
                    .background(CoachUIColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                MacroSummaryView(
                    style: .rings,
                    title: "Today",
                    calories: macroProgress(
                        current: todayNutrition.calories,
                        target: viewModel.clientProfile.calorieTarget,
                        label: "Calories",
                        unit: "kcal",
                        color: CoachUIColor.accent
                    ),
                    protein: macroProgress(
                        current: todayNutrition.protein,
                        target: viewModel.clientProfile.proteinTarget,
                        label: "Protein",
                        unit: "g",
                        color: ProgressStyle.proteinBlue
                    ),
                    carbs: macroProgress(
                        current: todayNutrition.carbs,
                        target: viewModel.clientProfile.carbTarget,
                        label: "Carbs",
                        unit: "g",
                        color: .orange
                    ),
                    fat: macroProgress(
                        current: todayNutrition.fat,
                        target: viewModel.clientProfile.fatTarget,
                        label: "Fat",
                        unit: "g",
                        color: SyncFitTheme.fat
                    )
                )
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Progress")

            let bodyStat = ProgressAnalytics.bodyWeightStat(
                source: viewModel.progressDataSource,
                range: .oneMonth
            )

            ProgressPageCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Body weight")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(bodyStat.hasData ? (bodyStat.valueText ?? "—") : "No weight logged yet")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    if let delta = bodyStat.deltaText {
                        Text(delta)
                            .font(.system(size: 11))
                            .foregroundStyle(CoachUIColor.muted)
                    }
                }
            }

            let records = ProgressAnalytics.topPersonalRecords(source: viewModel.progressDataSource)
            ProgressPageCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top PRs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if records.isEmpty {
                        Text("No PRs yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(CoachUIColor.muted)
                    } else {
                        ForEach(records) { record in
                            HStack {
                                Text(record.exerciseName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Text("\(SyncFitFormat.decimal(record.prWeight)) lbs")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(CoachUIColor.accent)
                            }
                        }
                    }
                }
            }

            ProgressPageCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Progress photos")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("\(displayName) hasn't shared progress photos yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(CoachUIColor.muted)
                }
            }
        }
    }

    private func lockedSection(kind: String) -> some View {
        ProgressPageCard {
            Text("\(displayName) hasn't shared their \(kind) yet.")
                .font(.system(size: 12))
                .foregroundStyle(CoachUIColor.muted)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(CoachUIColor.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoachUIColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func macroProgress(current: Int, target: Int, label: String, unit: String, color: Color) -> MacroProgress {
        MacroProgress(current: current, target: max(target, 1), label: label, unit: unit, color: color)
    }

    private var workoutSessions: [CoachWorkoutSessionSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.workouts) {
            calendar.startOfDay(for: $0.date)
        }
        return grouped.keys.sorted(by: >).prefix(5).compactMap { day in
            guard let exercises = grouped[day] else { return nil }
            let volume = exercises.reduce(0.0) { partial, entry in
                partial + entry.sets.reduce(0) { $0 + Double($1.reps) * $1.weight }
            }
            let title = exercises.first?.exercise.primaryMuscleGroup ?? "Workout"
            return CoachWorkoutSessionSummary(
                id: day.ISO8601Format(),
                date: day,
                title: title,
                totalVolume: volume,
                exercises: exercises.sorted { $0.exercise.name < $1.exercise.name }
            )
        }
    }

    private var dailyNutrition: [CoachDailyNutritionSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.meals) {
            calendar.startOfDay(for: $0.date)
        }
        return grouped.keys.sorted(by: >).prefix(7).map { day in
            let items = grouped[day] ?? []
            return CoachDailyNutritionSummary(
                date: day,
                calories: items.reduce(0) { $0 + $1.calories },
                protein: items.reduce(0) { $0 + $1.protein }
            )
        }
        .sorted { $0.date < $1.date }
    }

    private var todayNutrition: (calories: Int, protein: Int, carbs: Int, fat: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let items = viewModel.meals.filter { calendar.isDate($0.date, inSameDayAs: today) }
        return (
            calories: items.reduce(0) { $0 + $1.calories },
            protein: items.reduce(0) { $0 + $1.protein },
            carbs: items.reduce(0) { $0 + $1.carbs },
            fat: items.reduce(0) { $0 + $1.fat }
        )
    }
}

private struct CoachWorkoutSessionSummary: Identifiable {
    let id: String
    let date: Date
    let title: String
    let totalVolume: Double
    let exercises: [WorkoutEntry]
}

private struct CoachDailyNutritionSummary: Identifiable {
    var id: Date { date }
    let date: Date
    let calories: Int
    let protein: Int
}

private struct CoachClientNutritionChart: View {
    let days: [CoachDailyNutritionSummary]

    private var maxCalories: Int {
        max(days.map(\.calories).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 days")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoachUIColor.muted)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(CoachUIColor.accent.opacity(0.85))
                            .frame(
                                height: max(8, CGFloat(day.calories) / CGFloat(maxCalories) * 72)
                            )
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9))
                            .foregroundStyle(CoachUIColor.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 96)

            HStack {
                ForEach(days) { day in
                    VStack(spacing: 2) {
                        Text("\(day.calories)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("\(day.protein)g P")
                            .font(.system(size: 8))
                            .foregroundStyle(CoachUIColor.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
