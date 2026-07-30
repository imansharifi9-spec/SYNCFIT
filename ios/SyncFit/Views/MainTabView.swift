import SwiftUI
import FirebaseAuth

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var chatService: CoachChatService
    @EnvironmentObject private var authManager: AuthenticationManager

    var body: some View {
        Group {
            if coachService.isCoachModeActive {
                CoachMainTabView()
            } else {
                userTabView
            }
        }
        .sheet(isPresented: $appState.showingSyncFitPlusUpgrade) {
            SyncFitPlusUpgradeSheet(highlight: appState.syncFitPlusUpgradeHighlight)
        }
        .fullScreenCover(isPresented: $appState.showingAICoach) {
            AICompanionView()
        }
        .task(id: unreadMonitorKey) {
            await startUnreadMonitoringIfNeeded()
        }
        .onChange(of: coachService.isCoachModeActive) { _, _ in
            Task { await startUnreadMonitoringIfNeeded() }
        }
        .onChange(of: appState.isRestoringSession) { _, restoring in
            if !restoring {
                chatService.retryConversationsMonitoringAfterSessionRestoreIfNeeded()
            }
        }
    }

    private var unreadMonitorKey: String {
        let uid = Auth.auth().currentUser?.uid ?? ""
        let mode = coachService.isCoachModeActive ? "coach" : "client"
        let coachKey = coachService.portalProfile.coachUserID
        return "\(mode)|\(uid)|\(coachKey)"
    }

    private var userTabView: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            WorkoutView()
                .tabItem { Label("Workouts", systemImage: "dumbbell.fill") }
                .tag(AppTab.workouts)

            NutritionView()
                .tabItem { Label("Nutrition", systemImage: "fork.knife") }
                .tag(AppTab.nutrition)

            ProgressViewTab()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.progress)

            CoachesView()
                .tabItem {
                    Label("Coaches", systemImage: "person.2.fill")
                }
                // Empty string → system red-dot badge (no count), matching Home bell style.
                .badge(chatService.hasUnreadMessages ? "" : nil)
                .tag(AppTab.coaches)
        }
        .tint(SyncFitTheme.accent)
    }

    private func startUnreadMonitoringIfNeeded() async {
        let authUID = Auth.auth().currentUser?.uid ?? ""
        let portal = coachService.portalProfile.coachUserID
        let portalID = coachService.portalProfile.id.uuidString
        let line =
            "[ChatSync] MainTab startUnreadMonitoringIfNeeded " +
            "authenticated=\(authManager.isAuthenticated) " +
            "coachMode=\(coachService.isCoachModeActive) " +
            "authUID=\(authUID.isEmpty ? "(nil)" : authUID) " +
            "portalCoachUserID=\(portal.isEmpty ? "(empty)" : portal) " +
            "portalProfile.id=\(portalID) " +
            "portalCoachUserIDValid=\(CoachChatService.isValidConversationParticipantId(portal))"
        print(line)
        NSLog("%@", line)

        guard authManager.isAuthenticated,
              let uid = Auth.auth().currentUser?.uid else { return }

        if coachService.isCoachModeActive {
            // Prefer portal coachUserID when set; otherwise Auth uid.
            // Never fall back to portalProfile.id.uuidString.
            let portal = coachService.portalProfile.coachUserID
            let coachId = CoachChatService.isValidConversationParticipantId(portal) ? portal : uid
            guard CoachChatService.isValidConversationParticipantId(coachId) else { return }
            NSLog("[ChatSync] MainTab calling startUnreadMonitoring coachId=%@", coachId)
            chatService.startUnreadMonitoring(for: coachId)
        } else {
            guard CoachChatService.isValidConversationParticipantId(uid) else { return }
            NSLog("[ChatSync] MainTab calling startUnreadMonitoring clientUid=%@", uid)
            chatService.startUnreadMonitoring(for: uid)
        }
    }
}
