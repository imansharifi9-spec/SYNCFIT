import SwiftUI
import SwiftData

@main
struct SyncFitApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @StateObject private var appState: AppState
    @StateObject private var dataStore: FitnessDataStore
    @StateObject private var healthKit = HealthKitService()
    @StateObject private var authManager: AuthenticationManager
    @StateObject private var firestore: FirestoreDatabaseManager
    @StateObject private var coachService: CoachService
    @StateObject private var chatService: CoachChatService

    init() {
        FirebaseConfiguration.configureIfNeeded()
        let isFreshInstall = AuthenticationManager.prepareForFreshInstallIfNeeded()

        do {
            let container = try SyncFitModelContainer.make()
            self.container = container
            let context = container.mainContext
            SampleDataSeeder.seedIfNeeded(context: context)
            let appState = AppState(context: context)
            if isFreshInstall {
                appState.prepareForSignedOutState()
            }
            let dataStore = FitnessDataStore(context: context)
            let coachService = CoachService(context: context)
            let chatService = CoachChatService()
            _appState = StateObject(wrappedValue: appState)
            _dataStore = StateObject(wrappedValue: dataStore)
            _coachService = StateObject(wrappedValue: coachService)
            _chatService = StateObject(wrappedValue: chatService)
            _authManager = StateObject(wrappedValue: AuthenticationManager())
            _firestore = StateObject(wrappedValue: FirestoreDatabaseManager())
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(dataStore)
                .environmentObject(healthKit)
                .environmentObject(authManager)
                .environmentObject(firestore)
                .environmentObject(coachService)
                .environmentObject(chatService)
                .task {
                    configureIntegrations()
                    if authManager.isAuthenticated {
                        await syncUserSession()
                    }
                }
                .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
                    if isAuthenticated {
                        Task { await syncUserSession() }
                    } else if authManager.hasResolvedInitialAuthState {
                        handleUserSignedOut()
                    }
                }
                .onOpenURL { url in
                    _ = FirebaseConfiguration.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        dataStore.refreshCurrentCalendarDayIfNeeded()
                    }
                }
        }
        .modelContainer(container)
    }

    private func configureIntegrations() {
        dataStore.healthKit = healthKit
        dataStore.firestore = firestore
        coachService.configure(firestore: firestore)
        coachService.seedFromLocalStore(dataStore.coaches)
        dataStore.isHealthSyncEnabled = { [weak appState] in
            appState?.appleHealthSyncEnabled ?? false
        }
        healthKit.refreshConnectionStatus(isEnabled: appState.appleHealthSyncEnabled)

        if appState.appleHealthSyncEnabled {
            Task {
                await healthKit.refreshTodayActivity()
            }
        }
    }

    private func handleUserSignedOut() {
        // Do NOT wipe local profile/routines on sign-out for the same device user.
        // Wiping forced hasCompletedOnboarding=false and empty routines, which made
        // re-login flash onboarding and reset schedules. Cross-account switches clear
        // inside syncUserSession when the Firebase UID changes.
        AuthenticationManager.clearLastAuthenticatedUserID()
        coachService.resetForUserSwitch()
        chatService.teardown()
        appState.prepareForSignedOutState()
    }

    private func syncUserSession() async {
        // Always clear the restore gate, even on early exits / failures.
        // A stuck isRestoringSession=true freezes RootView on the spinner forever.
        appState.beginSessionRestore()
        defer { appState.endSessionRestore() }

        guard authManager.isAuthenticated,
              let uid = authManager.user?.uid else {
            print("[AuthScope] syncUserSession skipped — not authenticated")
            return
        }

        guard firestore.isAvailable else {
            print("[AuthScope] syncUserSession skipped — Firestore unavailable")
            return
        }

        let previousUID = AuthenticationManager.lastAuthenticatedUserID
        let switchedAccounts = previousUID != nil && previousUID != uid

        // Wipe device-local caches only when the authenticated Firebase UID changes.
        if switchedAccounts {
            dataStore.clearAllLocalUserData()
            coachService.resetForUserSwitch()
            chatService.teardown()
            appState.resetProfileForUserSwitch()
        }
        AuthenticationManager.lastAuthenticatedUserID = uid

        // Safety: if cloud calls hang, release the spinner after 10s so the app
        // can still show local state instead of freezing forever.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if appState.isRestoringSession {
                print("[AuthScope] Session restore watchdog releasing spinner")
                appState.endSessionRestore()
            }
        }

        do {
            print("[AuthScope] Restoring session for uid=\(uid)")
            let fetched = try await firestore.fetchUserProfileDetailed()
            let cloudProfile = fetched.profile

            // Reject cloud docs that somehow belong to another UID.
            if !cloudProfile.ownerUserID.isEmpty, cloudProfile.ownerUserID != uid {
                print("[AuthScope] Ignoring cloud profile owned by \(cloudProfile.ownerUserID) while signed in as \(uid)")
                appState.resetProfileForUserSwitch()
                return
            }

            // Full replace from users/{uid} — never keep leftover local height/weight/macros.
            appState.applyCloudProfile(cloudProfile)

            // Restore program-setup + schedule so returning users skip
            // "How do you want to start?" and keep their weekly plan.
            let inferredProgramSetup = cloudProfile.hasCompletedProgramSetup
                || !dataStore.routines.isEmpty
                || dataStore.weekSchedule.days.contains(where: { $0.kind != .unassigned })
            dataStore.applyCloudProgramState(
                hasCompletedProgramSetup: inferredProgramSetup,
                workoutScheduleJSON: cloudProfile.workoutScheduleJSON
            )

            // Stamp ownerUserID / program state on older docs for this UID.
            if cloudProfile.hasCompletedOnboarding {
                let needsBackfill = cloudProfile.ownerUserID.isEmpty
                    || fetched.missingBodyStatsInCloud
                    || cloudProfile.hasCompletedProgramSetup != dataStore.hasCompletedProgramSetup
                    || (cloudProfile.workoutScheduleJSON.isEmpty
                        && !dataStore.persistedWorkoutScheduleJSON().isEmpty)
                if needsBackfill {
                    try? await firestore.saveUserProfile(
                        appState.profile,
                        hasCompletedOnboarding: true,
                        hasCompletedProgramSetup: dataStore.hasCompletedProgramSetup,
                        workoutScheduleJSON: dataStore.persistedWorkoutScheduleJSON()
                    )
                }
            }

            await coachService.syncCoachStatusFromCloud(profileName: appState.profile.name)

            let data = try await firestore.fetchAllUserData()
            dataStore.mergeCloudData(
                weights: data.weights,
                meals: data.meals,
                workouts: data.workouts
            )
            await coachService.refreshClientCoachConnection()
            print("[AuthScope] Session restore complete onboarded=\(cloudProfile.hasCompletedOnboarding)")
        } catch {
            print("[AuthScope] syncUserSession failed: \(error)")
        }
    }
}
