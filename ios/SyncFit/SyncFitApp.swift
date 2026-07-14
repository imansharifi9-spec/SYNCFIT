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
    @StateObject private var subscriptionManager = SubscriptionManager()

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
                .environmentObject(subscriptionManager)
                .task {
                    configureIntegrations()
                    subscriptionManager.start()
                    if authManager.isAuthenticated {
                        await syncUserSession()
                        await subscriptionManager.recheckEntitlementsAfterLogin()
                    }
                }
                .onChange(of: authManager.isAuthenticated) { _, isAuthenticated in
                    if isAuthenticated {
                        Task {
                            await syncUserSession()
                            await subscriptionManager.recheckEntitlementsAfterLogin()
                        }
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
        subscriptionManager.configure(firestore: firestore, appState: appState)
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
        // Keep local cache for same-user re-login, but do NOT clear localDataOwnerUserID.
        // That key is how the next login detects a different account after sign-out.
        AuthenticationManager.clearLastAuthenticatedUserID()
        coachService.resetForUserSwitch()
        chatService.teardown()
        subscriptionManager.resetForLogout()
        appState.prepareForSignedOutState()
    }

    private func syncUserSession() async {
        // Always clear the restore gate, even on early exits / failures.
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

        // localDataOwnerUserID survives sign-out. Wipe whenever it does not match the
        // signing-in UID — including nil (upgrade path / leftover data with no owner).
        let localOwner = AuthenticationManager.localDataOwnerUserID
        let mustWipeLocalCache = localOwner != uid

        if mustWipeLocalCache {
            print("[AuthScope] Local cache owned by \(localOwner ?? "nil") — wiping for uid=\(uid)")
            dataStore.clearAllLocalUserData()
            coachService.resetForUserSwitch()
            chatService.teardown()
            appState.resetProfileForUserSwitch()
        }

        AuthenticationManager.lastAuthenticatedUserID = uid
        AuthenticationManager.localDataOwnerUserID = uid

        // Safety: if cloud calls hang, release the spinner after 10s.
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

            if !cloudProfile.ownerUserID.isEmpty, cloudProfile.ownerUserID != uid {
                print("[AuthScope] Ignoring cloud profile owned by \(cloudProfile.ownerUserID) while signed in as \(uid)")
                appState.resetProfileForUserSwitch()
                return
            }

            // Full replace from users/{uid} — never keep leftover local height/weight/macros.
            appState.applyCloudProfile(cloudProfile)

            // Program setup: trust cloud flag only. Never infer from leftover local routines
            // (that was a contamination path). Same-user local schedule is fine to keep.
            dataStore.applyCloudProgramState(
                hasCompletedProgramSetup: cloudProfile.hasCompletedProgramSetup,
                workoutScheduleJSON: cloudProfile.workoutScheduleJSON
            )

            // Backfill ownerUserID / body stats / program flag for older docs.
            // Never push local schedule to cloud when we just wiped for a new account
            // unless cloud already had a schedule (avoid polluting B with A's plan).
            if cloudProfile.hasCompletedOnboarding {
                let scheduleJSON = cloudProfile.workoutScheduleJSON.isEmpty
                    ? (mustWipeLocalCache ? "" : dataStore.persistedWorkoutScheduleJSON())
                    : cloudProfile.workoutScheduleJSON
                let needsBackfill = cloudProfile.ownerUserID.isEmpty
                    || fetched.missingBodyStatsInCloud
                    || (!cloudProfile.hasCompletedProgramSetup && dataStore.hasCompletedProgramSetup)
                if needsBackfill || (!cloudProfile.workoutScheduleJSON.isEmpty && scheduleJSON != cloudProfile.workoutScheduleJSON) {
                    try? await firestore.saveUserProfile(
                        appState.profile,
                        hasCompletedOnboarding: true,
                        hasCompletedProgramSetup: dataStore.hasCompletedProgramSetup
                            || cloudProfile.hasCompletedProgramSetup,
                        workoutScheduleJSON: scheduleJSON.isEmpty ? nil : scheduleJSON
                    )
                }
            }

            await coachService.syncCoachStatusFromCloud(profileName: appState.profile.name)
            await coachService.hydratePortalProfileFromCloudIfNeeded()

            let data = try await firestore.fetchAllUserData()
            let cloudRoutines = (try? await firestore.fetchRoutines()) ?? []
            // Always replace local logs with this UID's cloud history (no additive merge).
            dataStore.replaceCloudData(
                weights: data.weights,
                meals: data.meals,
                workouts: data.workouts,
                routines: cloudRoutines
            )
            // Progress photos: merge cloud metadata (images load from Storage / local cache).
            if let cloudPhotos = try? await firestore.fetchProgressPhotos() {
                dataStore.mergeCloudProgressPhotos(cloudPhotos)
            }
            // Push any schedule-referenced routines that only existed locally, then
            // rebuild empty day projections from those routine IDs.
            dataStore.syncReferencedRoutinesToCloudIfNeeded()
            dataStore.rehydrateScheduledDayPlansIfNeeded()
            await coachService.refreshClientCoachConnection()
            print("[AuthScope] Session restore complete onboarded=\(cloudProfile.hasCompletedOnboarding) programSetup=\(dataStore.hasCompletedProgramSetup)")
        } catch {
            print("[AuthScope] syncUserSession failed: \(error)")
        }
    }
}
