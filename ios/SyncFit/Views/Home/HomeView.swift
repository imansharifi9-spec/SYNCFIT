import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import UIKit

private enum HomePalette {
    static let pageBackground = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let consistencyGreen = SyncFitTheme.primaryAction
    static let missionGreen = SyncFitTheme.primaryAction
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
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
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
                            ProfileAvatarView(
                                size: 28,
                                userID: Auth.auth().currentUser?.uid ?? "",
                                photoFileName: appState.profile.photoFileName,
                                photoURL: appState.profile.photoURL
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("homeProfileButton")
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
            let session = dataStore.workoutDayDisplayTitle(for: .now)
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
        let sessionName = dataStore.workoutDayDisplayTitle(for: .now)
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
        let isSubscribed = subscriptionManager.isSubscribed
        #if DEBUG
        let showing = isSubscribed ? "AI Coach" : "upgrade CTA"
        let _ = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            print(
                "[HomeBanner] \(formatter.string(from: Date())) Rendering with " +
                "isSubscribed=\(isSubscribed), showing: \(showing)"
            )
        }()
        #endif

        return Button {
            if subscriptionManager.isSubscribed {
                appState.presentAICoach()
            } else {
                appState.presentSyncFitPlusUpgrade()
            }
        } label: {
            HStack(spacing: 14) {
                AICompanionOrbPreview()
                    .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 8) {
                    Text("✦ \(SyncFitPlusBrand.name)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(HomePalette.missionGreen)
                        .tracking(0.8)

                    Text("Meet your AI Coach")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)

                    Text(isSubscribed ? primaryInsightMessage : "Personal guidance from your actual workouts, meals, protein, and progress — not generic advice.")
                        .font(.system(size: 11))
                        .foregroundStyle(HomePalette.hintMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(isSubscribed ? "Open AI Coach →" : SyncFitPlusBrand.unlockButton)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HomePalette.missionGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 26 / 255, green: 58 / 255, blue: 26 / 255))
                        .clipShape(Capsule())
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [
                    HomePalette.aiCardBackground,
                    Color(red: 10 / 255, green: 34 / 255, blue: 18 / 255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HomePalette.missionGreen.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: HomePalette.missionGreen.opacity(0.12), radius: 18, y: 8)
        .buttonStyle(.plain)
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

// MARK: - AI Coach

private struct AICompanionMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let createdAt: Date

    var isUser: Bool { role == .user }
}

@MainActor
private final class AICompanionService: ObservableObject {
    @Published private(set) var messages: [AICompanionMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var orbActivity: AICoachOrbActivity = .idle
    @Published var errorMessage: String?

    private let functions = Functions.functions()
    private var listener: ListenerRegistration?
    private var activeConversationId: String?

    func start(conversationId: String = "primary") {
        stop()
        activeConversationId = conversationId

        guard FirebaseConfiguration.isConfigured else {
            errorMessage = "Firebase is not configured."
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            errorMessage = "Sign in required."
            return
        }

        listener = Firestore.firestore()
            .collection("users")
            .document(uid)
            .collection("aiCompanionConversations")
            .document(conversationId)
            .collection("messages")
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                Task { @MainActor in
                    if let error {
                        self.errorMessage = error.localizedDescription
                        #if DEBUG
                        print("[AICompanion] message listen failed: \(error)")
                        #endif
                        return
                    }
                    self.messages = (snapshot?.documents ?? []).compactMap(Self.parseMessage)
                }
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
        activeConversationId = nil
        messages = []
        errorMessage = nil
        orbActivity = .idle
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Auth.auth().currentUser != nil else {
            errorMessage = "Sign in required."
            return
        }

        let conversationId = activeConversationId ?? "primary"
        isSending = true
        errorMessage = nil
        orbActivity = .thinking

        do {
            _ = try await functions
                .httpsCallable("aiCompanionChat")
                .call([
                    "conversationId": conversationId,
                    "message": trimmed
                ])
            isSending = false
            // A short, energetic answer-arrived beat; visual impact lives in the orb.
            orbActivity = .responding
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if orbActivity == .responding {
                orbActivity = .idle
            }
        } catch {
            isSending = false
            orbActivity = .idle
            errorMessage = (error as NSError).localizedDescription
            #if DEBUG
            print("[AICompanion] send failed: \(error)")
            #endif
        }
    }

    private static func parseMessage(_ document: QueryDocumentSnapshot) -> AICompanionMessage? {
        let data = document.data()
        guard let text = data["text"] as? String, !text.isEmpty else { return nil }
        let roleRaw = (data["role"] as? String) ?? "assistant"
        let role = AICompanionMessage.Role(rawValue: roleRaw) ?? .assistant
        let timestamp = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        return AICompanionMessage(
            id: document.documentID,
            role: role,
            text: text,
            createdAt: timestamp
        )
    }
}

private enum AICompanionPalette {
    static let background = Color(red: 7 / 255, green: 10 / 255, blue: 8 / 255)
    static let card = Color(red: 14 / 255, green: 20 / 255, blue: 16 / 255)
    static let field = Color(red: 21 / 255, green: 28 / 255, blue: 23 / 255)
    static let accent = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)
    static let muted = Color(red: 145 / 255, green: 154 / 255, blue: 148 / 255)
}

/// Parses Claude Markdown for AI Coach assistant bubbles (headers, bold, lists).
enum AICoachChatMarkdown {
    /// Expands single newlines into paragraph breaks so CommonMark doesn't collapse
    /// Claude's "header\\nparagraph" into one dense run of text.
    static func normalizeParagraphBreaks(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Protect existing blank lines, then promote every remaining single newline
        // to a blank line. Already-double newlines stay as a single paragraph break.
        let placeholder = "\u{FFFC}"
        normalized = normalized.replacingOccurrences(of: "\n\n", with: placeholder)
        normalized = normalized.replacingOccurrences(of: "\n", with: "\n\n")
        normalized = normalized.replacingOccurrences(of: placeholder, with: "\n\n")

        // Collapse accidental 3+ blank lines down to one paragraph break.
        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return normalized
    }

    /// Paragraph/section blocks after spacing normalization — rendered with explicit
    /// VStack spacing so sections never visually glue together.
    static func blocks(from text: String) -> [String] {
        normalizeParagraphBreaks(text)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func attributedString(from text: String, normalize: Bool = true) -> AttributedString {
        let markdown = normalize ? normalizeParagraphBreaks(text) : text
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            return parsed
        }
        return AttributedString(markdown)
    }

    /// Renders one block from `blocks(from:)` — handles bullet lines split out of list
    /// context so `**bold**` still parses (standalone `- **text**` does not).
    static func attributedBlock(from block: String) -> AttributedString {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("- ") {
            var body = attributedString(from: String(trimmed.dropFirst(2)), normalize: false)
            var bullet = AttributedString("• ")
            bullet.append(body)
            return bullet
        }
        if trimmed.hasPrefix("• ") {
            var body = attributedString(from: String(trimmed.dropFirst(2)), normalize: false)
            var bullet = AttributedString("• ")
            bullet.append(body)
            return bullet
        }
        return attributedString(from: block, normalize: false)
    }
}

/// Activity-driven motion for the shared AI Coach orb (Home banner + full-screen).
enum AICoachOrbActivity: Equatable {
    case idle
    case thinking
    case responding
}

/// Home-banner sized AI Coach orb. Thin wrapper over the shared `AICoachOrb` so the
/// banner and the full-screen header can never drift apart — same rendering, different size.
private struct AICompanionOrbPreview: View {
    var body: some View {
        AICoachOrb(size: 78, activity: .idle)
    }
}

/// Holographic HUD-style AI Coach core — flat/graphic rings + bright core (not a 3D sphere).
/// Shared across Home banner and full-screen; `activity` only remaps motion rates.
private struct AICoachOrb: View {
    var size: CGFloat
    /// Soft ambient glow behind the HUD (full-screen header).
    var showsAmbient: Bool = false
    var activity: AICoachOrbActivity = .idle

    private var accent: Color { AICompanionPalette.accent }

    /// Smoothed motion — animated toward targets when `activity` changes.
    @State private var ringSpeed: Double = 0.35
    @State private var scanSpeed: Double = 0.55
    @State private var pulseRate: Double = 1.1
    @State private var pulseAmp: Double = 0.04
    @State private var coreGlow: Double = 0.85
    @State private var scanIntensity: Double = 0.55
    /// 1 while thinking so rings expand/contract with the core; 0 otherwise.
    @State private var ringPulseBlend: Double = 0.0
    /// Phase offsets so speed changes don't jump the ring/scan angles.
    @State private var ringPhase: Double = 0
    @State private var scanPhase: Double = 0
    /// Timestamp for the one-shot flare and scale bump when an answer arrives.
    @State private var respondingImpactStart: TimeInterval?

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = corePulse(at: t)
            // During thinking, rings share the pulse so the HUD expands/contracts as a unit.
            let ringScale = 1 + (pulse - 1) * ringPulseBlend
            let liveGlow = thinkingGlow(at: t, base: coreGlow)
            let responseImpact = respondingImpact(at: t)

            ZStack {
                if showsAmbient { ambient }

                // Soft even bloom — brightens/dims with thinking pulse.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accent.opacity(0.28 * liveGlow),
                                accent.opacity(0.08 * liveGlow),
                                .clear
                            ],
                            center: .center,
                            startRadius: size * 0.02,
                            endRadius: size * 0.48
                        )
                    )
                    .frame(width: size * 0.95, height: size * 0.95)
                    .blur(radius: size * 0.04)
                    .scaleEffect(ringScale)

                ZStack {
                    // Outer thin full ring (slow CW)
                    hudRing(diameter: size * 0.92, lineWidth: max(0.8, size * 0.008), opacity: 0.35)
                        .rotationEffect(.degrees(t * ringSpeed * 28 + ringPhase))

                    // Tick marks on mid-outer ring (CCW)
                    tickRing(diameter: size * 0.78, tickCount: 24)
                        .rotationEffect(.degrees(-t * ringSpeed * 42 - ringPhase * (42.0 / 28.0)))

                    // Segmented arc ring (CW, faster)
                    segmentedRing(
                        diameter: size * 0.64,
                        segments: 5,
                        span: 0.11,
                        gap: 0.09,
                        lineWidth: max(1.0, size * 0.012),
                        opacity: 0.75
                    )
                    .rotationEffect(.degrees(t * ringSpeed * 70 + ringPhase * (70.0 / 28.0)))

                    // Inner continuous ring (CCW)
                    hudRing(diameter: size * 0.46, lineWidth: max(0.7, size * 0.007), opacity: 0.45)
                        .rotationEffect(.degrees(-t * ringSpeed * 55 - ringPhase * (55.0 / 28.0)))

                    // Inner segmented micro-arcs (CW)
                    segmentedRing(
                        diameter: size * 0.34,
                        segments: 3,
                        span: 0.14,
                        gap: 0.19,
                        lineWidth: max(0.9, size * 0.01),
                        opacity: 0.55
                    )
                    .rotationEffect(.degrees(t * ringSpeed * 95 + ringPhase * (95.0 / 28.0)))

                    // Radar / scan sweep on the mid ring
                    scanSweep(diameter: size * 0.64, at: t, phase: scanPhase)
                        .opacity(scanIntensity)
                }
                .scaleEffect(ringScale)

                // Central glowing core — small bright disc, not a large lit ball.
                coreDisc(pulse: pulse, glow: liveGlow, responseImpact: responseImpact)
            }
            .frame(width: size, height: size)
            .scaleEffect(1 + responseImpact * 0.055)
        }
        .frame(width: size, height: size)
        .onAppear { applyMotion(for: activity, animated: false) }
        .onChange(of: activity) { _, newValue in
            applyMotion(for: newValue, animated: true)
        }
    }

    private func corePulse(at t: TimeInterval) -> Double {
        switch activity {
        case .idle:
            return 1 + sin(t * pulseRate) * abs(sin(t * pulseRate)) * pulseAmp
        case .thinking:
            // Calm, steady expand/contract — primary motion while working.
            return 1 + sin(t * pulseRate) * pulseAmp
        case .responding:
            let wave = sin(t * pulseRate) + 0.4 * sin(t * pulseRate * 2.0)
            return 1 + wave * pulseAmp
        }
    }

    /// Brighten/dim locked to the thinking pulse; idle/responding keep a steady glow.
    private func thinkingGlow(at t: TimeInterval, base: Double) -> Double {
        guard activity == .thinking else { return base }
        let unit = 0.5 + 0.5 * sin(t * pulseRate) // 0...1
        return base * (0.72 + 0.38 * unit)
    }

    /// Fast attack and smooth decay for the answer-arrived flash/pop.
    private func respondingImpact(at t: TimeInterval) -> Double {
        guard activity == .responding, let start = respondingImpactStart else { return 0 }
        let elapsed = max(0, t - start)
        let attack = 0.07
        let decay = 0.58
        if elapsed < attack {
            return elapsed / attack
        }
        let progress = min(1, (elapsed - attack) / decay)
        return pow(1 - progress, 2)
    }

    private func applyMotion(for activity: AICoachOrbActivity, animated: Bool) {
        let target: (
            ring: Double,
            scan: Double,
            pulse: Double,
            amp: Double,
            glow: Double,
            sweep: Double,
            ringPulse: Double
        )
        switch activity {
        case .idle:
            // Slow steady rotation (unchanged).
            target = (0.35, 0.55, 1.1, 0.04, 0.85, 0.45, 0.0)
        case .thinking:
            // Pulse-dominant: slow drift so it feels alive, not a full spin.
            // ring ~0.14 vs idle 0.35 / responding 0.65 — clearly secondary to pulse.
            target = (0.14, 0.20, 1.65, 0.10, 1.12, 0.20, 1.0)
        case .responding:
            // Fast, spin-dominant answer-arrived motion.
            target = (1.65, 2.10, 2.4, 0.07, 1.18, 0.90, 0.0)
        }

        let apply = {
            let now = Date().timeIntervalSinceReferenceDate
            if activity == .responding {
                respondingImpactStart = now
            }
            // Keep ring/scan angles continuous when speeds change (pulse → spin).
            ringPhase += now * (ringSpeed - target.ring) * 28
            scanPhase += now * (scanSpeed - target.scan) * 120
            ringSpeed = target.ring
            scanSpeed = target.scan
            pulseRate = target.pulse
            pulseAmp = target.amp
            coreGlow = target.glow
            scanIntensity = target.sweep
            ringPulseBlend = target.ringPulse
        }
        if animated {
            // Responding snaps in; other state handoffs remain calm and smooth.
            let duration = activity == .responding ? 0.18 : 0.65
            withAnimation(.easeInOut(duration: duration)) { apply() }
        } else {
            apply()
        }
    }

    private var ambient: some View {
        RadialGradient(
            colors: [
                accent.opacity(0.18),
                accent.opacity(0.05),
                .clear
            ],
            center: .center,
            startRadius: size * 0.08,
            endRadius: size * 0.72
        )
    }

    private func coreDisc(pulse: Double, glow: Double, responseImpact: Double) -> some View {
        let coreSize = size * 0.14
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.92 * responseImpact),
                            accent.opacity(0.65 * responseImpact),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: coreSize * 1.8
                    )
                )
                .frame(width: coreSize * 3.6, height: coreSize * 3.6)
                .blur(radius: coreSize * 0.28)
            Circle()
                .fill(accent.opacity(0.55 * glow))
                .frame(width: coreSize * 2.2, height: coreSize * 2.2)
                .blur(radius: coreSize * 0.55)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.95),
                            accent,
                            accent.opacity(0.35)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: coreSize * 0.55
                    )
                )
                .frame(width: coreSize, height: coreSize)
            // Even technical rim — no offset specular highlight.
            Circle()
                .strokeBorder(accent.opacity(0.9), lineWidth: max(0.6, size * 0.006))
                .frame(width: coreSize * 1.35, height: coreSize * 1.35)
        }
        .scaleEffect(pulse * (1 + responseImpact * 0.22))
        .allowsHitTesting(false)
    }

    private func hudRing(diameter: CGFloat, lineWidth: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(accent.opacity(opacity), lineWidth: lineWidth)
            .frame(width: diameter, height: diameter)
    }

    private func segmentedRing(
        diameter: CGFloat,
        segments: Int,
        span: CGFloat,
        gap: CGFloat,
        lineWidth: CGFloat,
        opacity: Double
    ) -> some View {
        ZStack {
            ForEach(0..<segments, id: \.self) { index in
                let start = CGFloat(index) * (span + gap)
                Circle()
                    .trim(from: start, to: start + span)
                    .stroke(
                        accent.opacity(opacity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .frame(width: diameter, height: diameter)
            }
        }
    }

    private func tickRing(diameter: CGFloat, tickCount: Int) -> some View {
        let tickLength = size * 0.028
        let tickWidth = max(0.6, size * 0.005)
        return ZStack {
            // Faint base ring under the ticks.
            Circle()
                .stroke(accent.opacity(0.18), lineWidth: max(0.5, size * 0.005))
                .frame(width: diameter, height: diameter)

            ForEach(0..<tickCount, id: \.self) { index in
                Capsule()
                    .fill(accent.opacity(index.isMultiple(of: 4) ? 0.75 : 0.35))
                    .frame(width: tickWidth, height: tickLength)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(Double(index) / Double(tickCount) * 360))
            }
        }
        .frame(width: diameter + tickLength, height: diameter + tickLength)
    }

    /// Thin bright sweep arc — radar / scan feel on one ring.
    private func scanSweep(diameter: CGFloat, at t: TimeInterval, phase: Double) -> some View {
        let angle = t * scanSpeed * 120 + phase
        return ZStack {
            Circle()
                .trim(from: 0.0, to: 0.12)
                .stroke(
                    AngularGradient(
                        colors: [
                            .clear,
                            accent.opacity(0.15),
                            .white.opacity(0.95),
                            accent.opacity(0.4),
                            .clear
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: max(1.4, size * 0.016), lineCap: .round)
                )
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(angle))

            // Leading tip — small bright node.
            Circle()
                .fill(.white.opacity(0.9))
                .frame(width: max(2, size * 0.022), height: max(2, size * 0.022))
                .offset(y: -diameter / 2)
                .rotationEffect(.degrees(angle + 360 * 0.12))
                .shadow(color: accent.opacity(0.8), radius: size * 0.02)
        }
        .allowsHitTesting(false)
    }
}

struct AICompanionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var companion = AICompanionService()
    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !companion.isSending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                orbHeader
                Divider()
                    .overlay(AICompanionPalette.accent.opacity(0.12))
                chatList
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .background(AICompanionPalette.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(AICompanionPalette.accent)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("AI Coach")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("SyncFit+")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AICompanionPalette.accent.opacity(0.85))
                    }
                }
            }
            .onAppear {
                companion.start()
            }
            .onDisappear {
                companion.stop()
            }
        }
    }

    private var orbHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                // Dark base so the orb's own ambient/bloom reads as illuminating the space.
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 8 / 255, green: 16 / 255, blue: 11 / 255),
                                Color(red: 3 / 255, green: 5 / 255, blue: 4 / 255)
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: 220
                        )
                    )

                // Same orb as the Home banner, just larger + ambient — activity tracks chat lifecycle.
                AICoachOrb(size: 260, showsAmbient: true, activity: companion.orbActivity)
                    .allowsHitTesting(false)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(AICompanionPalette.accent.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: AICompanionPalette.accent.opacity(0.28), radius: 36, y: 8)
            .padding(.horizontal, 18)
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Ask about your actual training and nutrition.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("I can spot consistency, recovery, protein gaps, and what to progress next from your SyncFit logs.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AICompanionPalette.muted)
                    .padding(.horizontal, 30)
            }
            .padding(.bottom, 12)
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if companion.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(companion.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }

                    if companion.isSending {
                        typingRow
                            .id("typing")
                    }

                    if let error = companion.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: companion.messages) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: companion.isSending) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AICompanionPalette.accent)
            Text("\"What should I focus on this week?\"")
            Text("\"Am I eating enough protein for my goal?\"")
            Text("\"Which lift should I progress next?\"")
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.86))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AICompanionPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AICompanionPalette.accent.opacity(0.12), lineWidth: 1)
        }
    }

    private func messageBubble(_ message: AICompanionMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 36) }
            Group {
                if message.isUser {
                    Text(message.text)
                } else {
                    // Split on paragraph breaks so headers / lists / body never glue into one wall of text.
                    let blocks = AICoachChatMarkdown.blocks(from: message.text)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Text(AICoachChatMarkdown.attributedBlock(from: block))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(message.isUser ? .black : .white)
            .tint(message.isUser ? .black : AICompanionPalette.accent)
            .multilineTextAlignment(message.isUser ? .trailing : .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.isUser ? AICompanionPalette.accent : AICompanionPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: message.isUser ? .trailing : .leading)
            if !message.isUser { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private var typingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(AICompanionPalette.accent)
            Text("Thinking with your recent logs...")
                .font(.caption)
                .foregroundStyle(AICompanionPalette.muted)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask your AI Coach...", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.sentences)
                .focused($isInputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(AICompanionPalette.field)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend ? .black : .white.opacity(0.45))
                    .frame(width: 38, height: 38)
                    .background(canSend ? AICompanionPalette.accent : Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(AICompanionPalette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task {
            await companion.send(text)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let id = companion.isSending ? "typing" : companion.messages.last?.id
        guard let id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}
