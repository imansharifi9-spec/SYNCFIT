import SwiftUI
import FirebaseAuth

private enum HomePalette {
    static let pageBackground = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let consistencyGreen = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)
    static let missionGreen = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)
    static let missionLabelGreen = Color(red: 74 / 255, green: 138 / 255, blue: 90 / 255)
    static let track = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let emptyCheckbox = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let emptyDot = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let workoutCardBackground = Color(red: 30 / 255, green: 58 / 255, blue: 34 / 255)
    static let workoutCardLabel = Color(red: 74 / 255, green: 138 / 255, blue: 90 / 255)
    static let tileBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let tileBorder = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let coachRowBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let coachRowBorder = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let hintMuted = Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255)
    static let aiCardBackground = Color(red: 15 / 255, green: 26 / 255, blue: 15 / 255)
    static let aiCardBorder = Color(red: 30 / 255, green: 58 / 255, blue: 30 / 255)
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var chatService: CoachChatService
    @EnvironmentObject private var coachService: CoachService
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingNotifications = false
    @State private var activeChat: CoachChatRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    greetingSection
                    missionSection
                    todaysWorkoutCard
                    statsRow
                    syncFitPlusCard

                    if let unread = chatService.unreadCoachConversations.first {
                        coachMessageRow(unread)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(HomePalette.pageBackground)
            .navigationBarTitleDisplayMode(.inline)
            .id(dataStore.currentCalendarDay)
            .onAppear {
                refreshHomeData()
            }
            .task {
                refreshHomeData()
                await refreshUnreadMessages()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showingNotifications = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bell")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white)

                                if chatService.hasUnreadCoachMessages {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 3, y: -3)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ProfileView()
                        } label: {
                            HomeProfileAvatar(name: firstName, size: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .sheet(isPresented: $showingNotifications) {
                HomeNotificationsSheet(
                    unreadConversations: chatService.unreadCoachConversations,
                    onOpenChat: { conversation in
                        showingNotifications = false
                        openChat(for: conversation)
                    }
                )
            }
            .navigationDestination(item: $activeChat) { route in
                CoachChatView(
                    conversationId: route.conversationId,
                    coachId: route.coachId,
                    coachName: route.coachName,
                    coachSpecialty: route.coachSpecialty,
                    userId: route.userId,
                    userName: route.userName,
                    viewingAsCoach: false
                )
            }
        }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        Text("\(timeBasedGreeting), \(firstName)")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
    }

    private var timeBasedGreeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 0..<5: return "Good Night"
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    private var firstName: String {
        if let displayName = Auth.auth().currentUser?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            let part = displayName.split(separator: " ").first.map(String.init)
            if let part, !part.isEmpty { return part }
            return displayName
        }

        let profileName = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profileName.isEmpty {
            return profileName.split(separator: " ").first.map(String.init) ?? profileName
        }

        return "Athlete"
    }

    // MARK: - Mission

    private var missionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today's Mission")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomePalette.missionLabelGreen)
                Spacer()
                Text(missionPercentageText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        completedGoalsCount == 2 ? HomePalette.missionGreen : HomePalette.hintMuted
                    )
            }

            HomeMissionProgressBar(progress: overallMissionProgress)

            VStack(alignment: .leading, spacing: 12) {
                    missionRow(
                        title: "Hit protein goal",
                        completed: proteinGoalMet,
                        detail: "\(Int(todayProteinLogged))g / \(Int(proteinGoal))g logged"
                    )
                    missionRow(
                        title: "Complete daily workout",
                        completed: todayWorkoutState == .completed,
                        detail: workoutMissionDetail
                    )

                    weeklyConsistencySection
            }
        }
    }

    private var todayProteinLogged: Int {
        dataStore.totalProteinToday()
    }

    private var proteinGoal: Int {
        appState.profile.proteinTarget
    }

    private var proteinGoalMet: Bool {
        todayProteinLogged >= proteinGoal
    }

    private var weeklyConsistencySection: some View {
        let summary = dataStore.weeklyConsistencySummary(proteinTarget: proteinGoal)
        let todayIndex = DayHistory.mondayToSundayDates()
            .firstIndex(where: { Calendar.current.isDateInToday($0) })

        return VStack(alignment: .leading, spacing: 10) {
            ConsistencyMetricRow(
                title: "Workouts",
                completedDays: summary.workoutDays,
                totalDays: summary.eligibleDays,
                dayStates: summary.workoutFlags,
                fillColor: ConsistencyVisualStyle.workoutGreen,
                showWeekdayLabels: true,
                todayIndex: todayIndex
            )

            ConsistencyMetricRow(
                title: "Protein goal",
                completedDays: summary.proteinDays,
                totalDays: summary.eligibleDays,
                dayStates: summary.proteinFlags,
                fillColor: ConsistencyVisualStyle.proteinBlue,
                showWeekdayLabels: false,
                todayIndex: todayIndex
            )
        }
        .padding(.top, 4)
    }

    private var todayWorkoutState: WorkoutSessionState {
        dataStore.workoutSessionState(for: .now)
    }

    private var isRestDayToday: Bool {
        dataStore.isRestDay(for: .now)
    }

    private var completedGoalsCount: Int {
        var count = 0
        if proteinGoalMet { count += 1 }
        if todayWorkoutState == .completed { count += 1 }
        return count
    }

    private var overallMissionProgress: Double {
        Double(completedGoalsCount) / 2.0
    }

    private var missionPercentageText: String {
        "\(Int((overallMissionProgress * 100).rounded()))%"
    }

    private var workoutMissionDetail: String {
        switch todayWorkoutState {
        case .completed:
            let session = dataStore.todayWorkoutSessionName()
                ?? dataStore.routine(for: .now)?.name
                ?? dataStore.routineDisplayName(for: .now)
            return "\(session) complete"
        case .inProgress:
            let done = dataStore.exercisesWithLoggedSetsCount(on: .now)
            let total = max(dataStore.plannedExerciseCount(for: .now), done)
            return "\(done) of \(total) exercises done"
        case .notStarted:
            if isRestDayToday {
                return "Rest day"
            }
            if !dataStore.hasScheduledWorkout(for: .now) {
                return "No workout scheduled"
            }
            return "Not started yet"
        }
    }

    private func missionRow(title: String, completed: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(completed ? HomePalette.missionGreen : HomePalette.emptyCheckbox)
                    .frame(width: 20, height: 20)
                if completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(completed ? HomePalette.missionLabelGreen : HomePalette.hintMuted)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Today's Workout

    private var todaysWorkoutCard: some View {
        Group {
            if isRestDayToday {
                restDayCard
            } else if dataStore.hasScheduledWorkout(for: .now) {
                activeWorkoutCard
            } else {
                emptyWorkoutCard
            }
        }
    }

    private var restDayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rest Day 😴")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text("Recovery is part of the plan.")
                .font(.system(size: 12))
                .foregroundStyle(HomePalette.workoutCardLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(HomePalette.workoutCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyWorkoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TODAY'S WORKOUT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(HomePalette.workoutCardLabel)
                .tracking(0.8)

            Text("No workout scheduled")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Text("Set up your weekly plan in Workouts.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HomePalette.workoutCardLabel)

            Button("Plan workout →") {
                appState.selectedTab = .workouts
                appState.shouldPresentScheduleSetup = true
            }
            .buttonStyle(HomeGhostWorkoutButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(HomePalette.workoutCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activeWorkoutCard: some View {
        let sessionName = dataStore.todayWorkoutSessionName()
            ?? dataStore.routine(for: .now)?.name
            ?? dataStore.routineDisplayName(for: .now)
        let exerciseCount = dataStore.plannedExerciseCount(for: .now)
        let state = todayWorkoutState
        let statusLine = workoutStatusLine(state: state, exerciseCount: exerciseCount)

        return VStack(alignment: .leading, spacing: 10) {
            Text("TODAY'S WORKOUT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(HomePalette.workoutCardLabel)
                .tracking(0.8)

            Text(sessionName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HomePalette.workoutCardLabel)

            workoutActionButton(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(HomePalette.workoutCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func refreshHomeData() {
        dataStore.refreshCurrentCalendarDayIfNeeded()
        dataStore.reload()
    }

    private func workoutStatusLine(state: WorkoutSessionState, exerciseCount: Int) -> String {
        let exerciseLabel = exerciseCount == 1 ? "exercise" : "exercises"
        switch state {
        case .completed:
            return "\(exerciseCount) \(exerciseLabel) · Completed ✓"
        case .inProgress:
            let done = dataStore.exercisesWithLoggedSetsCount(on: .now)
            let total = max(exerciseCount, done)
            return "\(done) of \(total) done"
        case .notStarted:
            return "\(exerciseCount) \(exerciseLabel) · Ready"
        }
    }

    @ViewBuilder
    private func workoutActionButton(state: WorkoutSessionState) -> some View {
        switch state {
        case .notStarted:
            Button("Start workout →") {
                handleWorkoutAction(.startWorkout)
            }
            .buttonStyle(HomePrimaryWorkoutButtonStyle())
        case .inProgress:
            Button("Continue workout →") {
                handleWorkoutAction(.resumeWorkout)
            }
            .buttonStyle(HomePrimaryWorkoutButtonStyle())
        case .completed:
            Button("View session →") {
                handleWorkoutAction(.viewCompleted)
            }
            .buttonStyle(HomeGhostWorkoutButtonStyle())
        }
    }

    private func handleWorkoutAction(_ action: WorkoutHomeAction) {
        appState.selectedTab = .workouts
        appState.pendingWorkoutHomeAction = action
    }

    // MARK: - Stats row

    private var statsRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                calorieStatTile
                proteinStatTile
            }
            weightStatTile
        }
    }

    private var weightStatTile: some View {
        let isMetric = appState.profile.measurementSystem == .metric
        let lbs = dataStore.currentBodyWeightLbs(profile: appState.profile)
        let value = isMetric ? lbs * 0.453592 : lbs

        return Button {
            appState.selectedTab = .progress
        } label: {
            HomeStatTile(style: .compact) {
                Text(SyncFitFormat.decimal(value))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomePalette.hintMuted)
                Text(isMetric ? "kg" : "lbs")
                    .font(.system(size: 8))
                    .foregroundStyle(HomePalette.hintMuted.opacity(0.75))
            }
        }
        .buttonStyle(HomeStatTileButtonStyle())
    }

    private var calorieStatTile: some View {
        let display = CalorieGoalDisplay(
            current: dataStore.totalCaloriesToday(),
            target: appState.profile.calorieTarget
        )

        return Button {
            appState.selectedTab = .nutrition
        } label: {
            HomeStatTile(style: .primary) {
                Text(display.formattedCurrent)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(display.tileValueColor)
                Text(display.tileSubtitle)
                    .font(.system(size: 10, weight: display.tileSubtitleIsAction ? .medium : .regular))
                    .foregroundStyle(display.tileSubtitleColor)
            }
        }
        .buttonStyle(HomeStatTileButtonStyle())
    }

    private var proteinStatTile: some View {
        let protein = dataStore.totalProteinToday()
        let goal = proteinGoal
        let goalHit = protein >= goal && goal > 0

        return Button {
            appState.selectedTab = .nutrition
        } label: {
            HomeStatTile(style: .primary) {
                Text("\(protein)g")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(goalHit ? HomePalette.missionGreen : .white)
                if goalHit {
                    Text("Goal hit ✓")
                        .font(.system(size: 10))
                        .foregroundStyle(HomePalette.missionLabelGreen)
                } else {
                    Text("\(protein) / \(goal)g")
                        .font(.system(size: 10))
                        .foregroundStyle(HomePalette.hintMuted)
                }
            }
        }
        .buttonStyle(HomeStatTileButtonStyle())
    }

    // MARK: - SyncFit+

    private var syncFitPlusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("✦ \(SyncFitPlusBrand.name)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(HomePalette.missionGreen)
                .tracking(0.8)

            if appState.isSyncFitPlusSubscriber {
                Text(primaryInsightMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(HomePalette.hintMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(SyncFitPlusBrand.freeUserPitch)
                    .font(.system(size: 11))
                    .foregroundStyle(HomePalette.hintMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    appState.presentSyncFitPlusUpgrade()
                } label: {
                    Text(SyncFitPlusBrand.unlockButton)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HomePalette.missionGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 26 / 255, green: 58 / 255, blue: 26 / 255))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(HomePalette.aiCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HomePalette.aiCardBorder, lineWidth: 0.5)
        )
    }

    private var primaryInsightMessage: String {
        AIInsightService.dailyInsights(
            profile: appState.profile,
            dataStore: dataStore,
            limit: 1
        ).first?.message
            ?? "Log a workout and a meal today — SyncFit+ will turn your data into daily strength, recovery, and goal insights."
    }

    // MARK: - Coach message

    private func coachMessageRow(_ conversation: UnreadCoachConversation) -> some View {
        Button {
            openChat(for: conversation)
        } label: {
            HStack(spacing: 10) {
                HomeCoachAvatar(
                    name: conversation.coachName,
                    specialty: coachSpecialty(for: conversation.coachId),
                    size: 28
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(conversation.coachName) sent you a message")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(conversation.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(HomePalette.hintMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Circle()
                    .fill(HomePalette.missionGreen)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(HomePalette.coachRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(HomePalette.coachRowBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func coachSpecialty(for coachId: String) -> String {
        coachService.marketplaceCoaches.first(where: { $0.coachFirestoreID == coachId })?.specialty ?? ""
    }

    private func openChat(for conversation: UnreadCoachConversation) {
        activeChat = CoachChatRoute(
            conversationId: conversation.conversationId,
            coachId: conversation.coachId,
            coachName: conversation.coachName,
            coachSpecialty: coachSpecialty(for: conversation.coachId),
            userId: conversation.userId,
            userName: conversation.userName
        )
    }

    private func refreshUnreadMessages() async {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        await chatService.refreshUnreadForClient(userId: userId)
    }
}

// MARK: - Subviews

private struct HomeMissionProgressBar: View {
    let progress: Double
    @State private var animatedProgress: Double = 0

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ConsistencyVisualStyle.emptyDot)
                    .frame(height: 4)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ConsistencyVisualStyle.workoutGreen)
                    .frame(width: geometry.size.width * animatedProgress, height: 4)
            }
        }
        .frame(height: 4)
        .onAppear {
            animatedProgress = 0
            withAnimation(.easeInOut(duration: 0.5)) {
                animatedProgress = clampedProgress
            }
        }
        .onChange(of: progress) { _, _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                animatedProgress = clampedProgress
            }
        }
    }
}

private enum HomeStatTileStyle {
    case primary
    case compact

    var horizontalPadding: CGFloat {
        switch self {
        case .primary: 12
        case .compact: 10
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .primary: 12
        case .compact: 8
        }
    }
}

private struct HomeStatTile<Content: View>: View {
    var style: HomeStatTileStyle = .primary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: style == .primary ? 4 : 2) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, style.horizontalPadding)
        .padding(.vertical, style.verticalPadding)
        .background(HomePalette.tileBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(HomePalette.tileBorder, lineWidth: 0.5)
        )
    }
}

private struct HomeStatTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HomePrimaryWorkoutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(HomePalette.missionGreen.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HomeGhostWorkoutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HomePalette.hintMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255).opacity(configuration.isPressed ? 0.8 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HomeProfileAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(name.coachInitials)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 26 / 255, green: 58 / 255, blue: 26 / 255))
            .clipShape(Circle())
    }
}

private struct HomeCoachAvatar: View {
    let name: String
    let specialty: String
    let size: CGFloat

    private var backgroundColor: Color {
        let specialty = specialty.lowercased()
        switch specialty {
        case let s where s.contains("muscle"):
            return Color(red: 0.35, green: 0.2, blue: 0.45)
        case let s where s.contains("fat"), let s where s.contains("weight"):
            return Color(red: 0.2, green: 0.35, blue: 0.45)
        case let s where s.contains("power"):
            return Color(red: 0.45, green: 0.25, blue: 0.2)
        default:
            return Color(red: 0.25, green: 0.35, blue: 0.25)
        }
    }

    var body: some View {
        Text(name.coachInitials)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(backgroundColor)
            .clipShape(Circle())
    }
}

private struct HomeNotificationsSheet: View {
    let unreadConversations: [UnreadCoachConversation]
    var onOpenChat: (UnreadCoachConversation) -> Void

    @Environment(\.dismiss) private var dismiss

    private var items: [HomeNotificationItem] {
        unreadConversations.map { conversation in
            HomeNotificationItem(
                id: conversation.id,
                kind: .coachMessage,
                title: "\(conversation.coachName) sent you a message",
                preview: conversation.preview,
                timestamp: conversation.timestamp,
                chatRoute: CoachChatRoute(
                    conversationId: conversation.conversationId,
                    coachId: conversation.coachId,
                    coachName: conversation.coachName,
                    coachSpecialty: "",
                    userId: conversation.userId,
                    userName: conversation.userName
                )
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack {
                        Spacer()
                        Text("No notifications yet.")
                            .font(.subheadline)
                            .foregroundStyle(HomePalette.hintMuted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(items) { item in
                        Button {
                            if let conversation = unreadConversations.first(where: { $0.id == item.id }) {
                                onOpenChat(conversation)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(item.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState.preview())
        .environmentObject(FitnessDataStore.preview())
        .environmentObject(CoachChatService())
        .environmentObject(CoachService(context: try! SyncFitModelContainer.make(inMemory: true).mainContext))
}
