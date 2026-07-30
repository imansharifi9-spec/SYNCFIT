import SwiftUI
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class CoachClientDataViewModel: ObservableObject {
    @Published var workouts: [WorkoutEntry] = []
    @Published var meals: [FoodEntry] = []
    @Published var weights: [WeightEntry] = []
    @Published var progressPhotos: [ProgressPhotoEntry] = []
    @Published var clientProfile: FirestoreUserProfile = .empty
    @Published var lastListenError: String?
    @Published var resolvedConnection: CoachClientConnection?
    @Published var isPreparing = false

    private var listeners: [ListenerRegistration] = []
    /// Bumps on every start/stop so overlapping setup Tasks cannot attach after teardown.
    private var observationGeneration = 0
    private var activeClientUserID: String?

    /// Single entry point for the screen. Safe to call from `.task(id:)` — cancels prior
    /// generation, tears down listeners, then ensures + attaches once.
    func startObserving(connection: CoachClientConnection, firestore: FirestoreDatabaseManager) async {
        let clientKey = connection.clientUserID
        // Already live for this client — do not re-run ensureCanonical / re-attach.
        if activeClientUserID == clientKey, !listeners.isEmpty, !isPreparing {
            print("[CoachClientData] Skip restart — already listening client=\(clientKey) listeners=\(listeners.count)")
            return
        }

        beginNewObservationSession(expectedClient: clientKey)
        let generation = observationGeneration
        lastListenError = nil
        resolvedConnection = connection
        isPreparing = true
        defer {
            if observationGeneration == generation {
                isPreparing = false
            }
        }

        guard let coachAuthUID = Auth.auth().currentUser?.uid, !coachAuthUID.isEmpty else {
            lastListenError = "Not signed in as coach."
            return
        }

        do {
            print("[CoachClientData] Setup START gen=\(generation) client=\(clientKey) coach=\(coachAuthUID)")
            let live = try await firestore.ensureCanonicalCoachClientConnection(
                from: connection,
                coachAuthUID: coachAuthUID
            )

            guard observationGeneration == generation, !Task.isCancelled else {
                print("[CoachClientData] Setup ABORTED after ensure gen=\(generation) current=\(observationGeneration)")
                return
            }

            resolvedConnection = live
            print(
                "[CoachClientData] Ready to listen gen=\(generation) client=\(live.clientUserID) " +
                "doc=\(live.documentID) coachId=\(live.coachFirestoreID) " +
                "shareW=\(live.shareWorkouts) shareN=\(live.shareNutrition) shareP=\(live.shareProgress)"
            )

            if !live.shareWorkouts && !live.shareNutrition && !live.shareProgress {
                lastListenError =
                    "Sharing toggles are off on the connection document. " +
                    "Ask the client to turn them on again in Settings → My coach."
                return
            }

            // Tear down anything left, then attach exactly one set for this generation.
            removeAllListeners()
            guard observationGeneration == generation, !Task.isCancelled else { return }
            attachListeners(for: live, firestore: firestore, generation: generation)
            activeClientUserID = live.clientUserID
            print("[CoachClientData] Setup DONE gen=\(generation) listeners=\(listeners.count)")
        } catch is CancellationError {
            print("[CoachClientData] Setup cancelled gen=\(generation)")
        } catch {
            guard observationGeneration == generation else { return }
            print("[CoachClientData] ensureCanonical FAILED: \(error)")
            lastListenError = error.localizedDescription
        }
    }

    private func beginNewObservationSession(expectedClient: String) {
        observationGeneration += 1
        activeClientUserID = nil
        removeAllListeners()
        print("[CoachClientData] New session gen=\(observationGeneration) client=\(expectedClient)")
    }

    private func attachListeners(
        for connection: CoachClientConnection,
        firestore: FirestoreDatabaseManager,
        generation: Int
    ) {
        let clientUserID = connection.clientUserID

        let onError: (Error) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                let ns = error as NSError
                if ns.domain == FirestoreErrorDomain {
                    // Teardown and transient stream kills — keep last good snapshot.
                    if ns.code == FirestoreErrorCode.cancelled.rawValue
                        || ns.code == FirestoreErrorCode.aborted.rawValue {
                        return
                    }
                    // Already showing real data — don't flash the red banner over it
                    // when a later listener hop fails (permissions churn).
                    if ns.code == FirestoreErrorCode.permissionDenied.rawValue,
                       !self.workouts.isEmpty || !self.meals.isEmpty || !self.weights.isEmpty {
                        print("[CoachClientData] Ignoring late permission error; keeping loaded data gen=\(generation)")
                        return
                    }
                }
                self.lastListenError = error.localizedDescription
                print("[CoachClientData] Listen error gen=\(generation): \(error)")
            }
        }

        let stillCurrent: () -> Bool = { [weak self] in
            self?.observationGeneration == generation
        }

        if let listener = firestore.observeClientProfile(
            clientUserID: clientUserID,
            onChange: { [weak self] profile in
                Task { @MainActor in
                    guard stillCurrent() else { return }
                    self?.clientProfile = profile
                    self?.lastListenError = nil
                }
            },
            onError: onError
        ) {
            listeners.append(listener)
        }

        if connection.shareWorkouts,
           let listener = firestore.observeClientWorkouts(
            clientUserID: clientUserID,
            onChange: { [weak self] items in
                Task { @MainActor in
                    guard stillCurrent() else { return }
                    // Never let a teardown race replace loaded rows with [].
                    if items.isEmpty, let existing = self?.workouts, !existing.isEmpty {
                        print("[CoachClientData] Ignoring empty workouts overwrite (\(existing.count) kept)")
                        return
                    }
                    self?.workouts = items
                    if items.isEmpty == false { self?.lastListenError = nil }
                }
            },
            onError: onError
           ) {
            listeners.append(listener)
        }

        if connection.shareNutrition,
           let listener = firestore.observeClientMeals(
            clientUserID: clientUserID,
            onChange: { [weak self] items in
                Task { @MainActor in
                    guard stillCurrent() else { return }
                    if items.isEmpty, let existing = self?.meals, !existing.isEmpty {
                        print("[CoachClientData] Ignoring empty meals overwrite (\(existing.count) kept)")
                        return
                    }
                    self?.meals = items
                    if items.isEmpty == false { self?.lastListenError = nil }
                }
            },
            onError: onError
           ) {
            listeners.append(listener)
        }

        if connection.shareProgress {
            if let listener = firestore.observeClientWeights(
                clientUserID: clientUserID,
                onChange: { [weak self] items in
                    Task { @MainActor in
                        guard stillCurrent() else { return }
                        if items.isEmpty, let existing = self?.weights, !existing.isEmpty {
                            print("[CoachClientData] Ignoring empty weights overwrite (\(existing.count) kept)")
                            return
                        }
                        self?.weights = items
                        if items.isEmpty == false { self?.lastListenError = nil }
                    }
                },
                onError: onError
            ) {
                listeners.append(listener)
            }
            if let listener = firestore.observeClientProgressPhotos(
                clientUserID: clientUserID,
                onChange: { [weak self] items in
                    Task { @MainActor in
                        guard stillCurrent() else { return }
                        if items.isEmpty, let existing = self?.progressPhotos, !existing.isEmpty {
                            print("[CoachClientData] Ignoring empty photos overwrite (\(existing.count) kept)")
                            return
                        }
                        self?.progressPhotos = items
                    }
                },
                onError: onError
            ) {
                listeners.append(listener)
            }
        }
    }

    func stopObserving() {
        observationGeneration += 1
        activeClientUserID = nil
        removeAllListeners()
        isPreparing = false
        print("[CoachClientData] stopObserving gen=\(observationGeneration)")
    }

    private func removeAllListeners() {
        guard !listeners.isEmpty else { return }
        print("[CoachClientData] Removing \(listeners.count) listener(s)")
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    var progressDataSource: ProgressDataSource {
        ProgressDataSource(
            userId: nil,
            workouts: workouts,
            foods: meals,
            weights: weights,
            progressPhotos: progressPhotos,
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
    @EnvironmentObject private var coachService: CoachService
    @StateObject private var viewModel = CoachClientDataViewModel()
    @State private var showingSendRoutine = false
    @State private var showingDraftGoalPicker = false
    @State private var draftTemplate: CoachRoutineTemplate?
    @State private var isGeneratingDraft = false
    @State private var draftError: String?
    @State private var insightText: String?
    @State private var insightCached = false
    @State private var isLoadingInsight = false
    @State private var insightError: String?

    private var activeConnection: CoachClientConnection {
        viewModel.resolvedConnection ?? connection
    }

    private var displayName: String {
        let trimmed = activeConnection.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Anonymous" : trimmed
    }

    private var clientProfileHeader: some View {
        ProgressPageCard {
            HStack(spacing: 14) {
                ClientProfileAvatarView(
                    clientUserID: activeConnection.clientUserID,
                    photoFileName: viewModel.clientProfile.photoFileName,
                    photoURL: viewModel.clientProfile.photoURL,
                    size: 56
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Connected \(activeConnection.connectedAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                        .font(.system(size: 11))
                        .foregroundStyle(CoachUIColor.muted)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var clientInsightsCard: some View {
        ProgressPageCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("AI Client Insights", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if insightCached {
                        Text("Cached")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CoachUIColor.muted)
                    }
                    Button {
                        Task { await loadInsights(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CoachUIColor.accent)
                    }
                    .disabled(isLoadingInsight)
                }

                if isLoadingInsight && insightText == nil {
                    HStack(spacing: 8) {
                        ProgressView().tint(CoachUIColor.accent).scaleEffect(0.8)
                        Text("Scanning shared activity…")
                            .font(.system(size: 12))
                            .foregroundStyle(CoachUIColor.muted)
                    }
                } else if let insightError {
                    Text(insightError)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.92, green: 0.45, blue: 0.42))
                } else if let insightText {
                    let blocks = AICoachChatMarkdown.blocks(from: insightText)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Text(AICoachChatMarkdown.attributedBlock(from: block))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(white: 0.88))
                                .tint(CoachUIColor.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Quick-scan summary from shared workouts, nutrition, and progress.")
                        .font(.system(size: 12))
                        .foregroundStyle(CoachUIColor.muted)
                }
            }
        }
    }

    private var draftAIRoutineCard: some View {
        ProgressPageCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI Routine Draft")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Generate a draft from shared client data. Review and edit before sending.")
                    .font(.system(size: 12))
                    .foregroundStyle(CoachUIColor.muted)

                Button {
                    showingDraftGoalPicker = true
                } label: {
                    HStack {
                        if isGeneratingDraft {
                            ProgressView().tint(.black)
                        }
                        Text(isGeneratingDraft ? "Drafting…" : "Draft AI Routine")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "wand.and.stars")
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(CoachUIColor.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isGeneratingDraft)

                if let draftError {
                    Text(draftError)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.92, green: 0.45, blue: 0.42))
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                clientProfileHeader
                clientInsightsCard
                draftAIRoutineCard

                if viewModel.isPreparing {
                    ProgressPageCard {
                        HStack(spacing: 10) {
                            ProgressView().tint(CoachUIColor.accent)
                            Text("Checking sharing permissions…")
                                .font(.system(size: 12))
                                .foregroundStyle(CoachUIColor.muted)
                        }
                    }
                }

                if let error = viewModel.lastListenError {
                    ProgressPageCard {
                        Text("Couldn't load shared data: \(error)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.92, green: 0.45, blue: 0.42))
                    }
                }

                if activeConnection.shareWorkouts {
                    workoutsSection
                } else {
                    lockedSection(kind: "workouts")
                }

                if activeConnection.shareNutrition {
                    nutritionSection
                } else {
                    lockedSection(kind: "nutrition")
                }

                if activeConnection.shareProgress {
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
            CoachSendRoutineSheet(connection: activeConnection)
        }
        .sheet(isPresented: $showingDraftGoalPicker) {
            CoachAIDraftGoalPickerSheet { goal in
                showingDraftGoalPicker = false
                Task { await generateDraft(goal: goal) }
            }
        }
        .sheet(item: $draftTemplate) { template in
            CoachRoutineTemplateEditorView(template: template) { saved in
                do {
                    try await coachService.saveRoutineTemplate(saved)
                    return true
                } catch {
                    draftError = error.localizedDescription
                    return false
                }
            }
        }
        .task(id: connection.clientUserID) {
            await viewModel.startObserving(connection: connection, firestore: firestore)
            await loadInsights(forceRefresh: false)
            defer { viewModel.stopObserving() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func loadInsights(forceRefresh: Bool) async {
        isLoadingInsight = true
        insightError = nil
        defer { isLoadingInsight = false }
        do {
            let result = try await CoachAIToolsService.generateClientInsights(
                clientUserID: activeConnection.clientUserID,
                forceRefresh: forceRefresh
            )
            insightText = result.insight
            insightCached = result.cached
        } catch {
            insightError = error.localizedDescription
        }
    }

    private func generateDraft(goal: CoachAIRoutineGoal) async {
        isGeneratingDraft = true
        draftError = nil
        defer { isGeneratingDraft = false }
        do {
            let template = try await CoachAIToolsService.generateRoutineDraft(
                clientUserID: activeConnection.clientUserID,
                goal: goal
            )
            // Refresh library so Send Routine can pick this draft immediately after save.
            await coachService.refreshRoutineTemplates()
            draftTemplate = template
        } catch {
            draftError = error.localizedDescription
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
                    if viewModel.progressPhotos.isEmpty {
                        Text("\(displayName) hasn't shared progress photos yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(CoachUIColor.muted)
                    } else {
                        Text("\(viewModel.progressPhotos.count) photo\(viewModel.progressPhotos.count == 1 ? "" : "s") shared")
                            .font(.system(size: 11))
                            .foregroundStyle(CoachUIColor.muted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(viewModel.progressPhotos.prefix(6)) { photo in
                                    CoachClientProgressPhotoThumb(photo: photo)
                                }
                            }
                        }
                    }
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
                exercises: exercises
            )
        }
    }

    private var dailyNutrition: [CoachDailyNutritionSummary] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.meals) {
            calendar.startOfDay(for: $0.date)
        }
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)) ?? .now
        return (0..<7).compactMap { offset -> CoachDailyNutritionSummary? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
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

private struct CoachClientProgressPhotoThumb: View {
    let photo: ProgressPhotoEntry
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CoachUIColor.chipInactiveText.opacity(0.35))
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }
        }
        .frame(width: 64, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: photo.id) {
            image = await ProgressPhotoStorage.loadImage(for: photo)
        }
    }
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

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(CoachUIColor.accent.opacity(day.calories > 0 ? 0.85 : 0.25))
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

private struct CoachAIDraftGoalPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (CoachAIRoutineGoal) -> Void

    var body: some View {
        NavigationStack {
            List(CoachAIRoutineGoal.allCases) { goal in
                Button {
                    onSelect(goal)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(goal.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(goal.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Draft Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
