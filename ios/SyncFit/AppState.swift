import Foundation
import SwiftData

enum AppTab: Hashable {
    case home
    case workouts
    case nutrition
    case progress
    case coaches
}

enum WorkoutHomeAction: Equatable {
    case startWorkout
    case resumeWorkout
    case viewCompleted
}

@MainActor
final class AppState: ObservableObject {
    @Published var hasCompletedOnboarding = false
    @Published var profile = UserProfile()
    @Published var appearance: AppAppearance = .dark
    @Published var appleHealthSyncEnabled = false
    @Published var nutritionMacroDisplayStyle: NutritionMacroDisplayStyle = .bars
    @Published var restTimerSeconds: Int = 90
    @Published var showingSyncFitPlusUpgrade = false
    @Published var syncFitPlusUpgradeHighlight: SyncFitPlusFeature = .general
    @Published var showingAICoach = false
    @Published var selectedTab: AppTab = .home
    @Published var shouldPresentScheduleSetup = false
    @Published var pendingWorkoutHomeAction: WorkoutHomeAction?
    /// True while restoring the authenticated user's cloud profile after login.
    /// RootView must wait on this so already-onboarded users never flash onboarding.
    @Published var isRestoringSession = false
    /// False until the first `syncUserSession` finishes this process lifetime.
    /// Closes the cold-launch window where MainTab mounts before restore starts
    /// (auth resolved, `isRestoringSession` still false for a frame) and the
    /// conversations listener attaches with a not-yet-accepted Firestore Auth token.
    private(set) var hasFinishedSessionRestoreThisLaunch = false

    private let context: ModelContext
    private var settings: AppSettings

    init(context: ModelContext) {
        self.context = context
        self.settings = AppState.loadOrCreateSettings(context: context)
        syncFromSettings()
    }

    func prepareForSignedOutState() {
        // Keep local profile/onboarding flags for the last account so a same-user
        // re-login can skip onboarding immediately. Cross-account switches clear
        // via resetProfileForUserSwitch() before cloud restore.
        selectedTab = .home
        showingSyncFitPlusUpgrade = false
        showingAICoach = false
        isRestoringSession = false
        hasFinishedSessionRestoreThisLaunch = false
        settings.isAuthenticated = false
        try? context.save()
    }

    func reloadFromSettings() {
        settings = Self.loadOrCreateSettings(context: context)
        syncFromSettings()
    }

    /// Replaces the in-memory/local profile with the authenticated user's cloud document.
    /// Never merges into leftover fields from a previous account on this device.
    func applyCloudProfile(_ cloud: FirestoreUserProfile) {
        hasCompletedOnboarding = cloud.hasCompletedOnboarding
        if cloud.hasCompletedOnboarding {
            profile = cloud.asUserProfile()
        } else {
            profile = UserProfile()
        }
        persist()
    }

    /// Clears local profile state before loading a different authenticated user.
    func resetProfileForUserSwitch() {
        hasCompletedOnboarding = false
        profile = UserProfile()
        selectedTab = .home
        showingSyncFitPlusUpgrade = false
        showingAICoach = false
        settings.hasCompletedOnboarding = false
        settings.hasCompletedProgramSetup = false
        settings.profile = UserProfile()
        settings.workoutScheduleJSON = ""
        settings.isAuthenticated = false
        try? context.save()
        objectWillChange.send()
    }

    func beginSessionRestore() {
        isRestoringSession = true
    }

    func endSessionRestore() {
        isRestoringSession = false
        hasFinishedSessionRestoreThisLaunch = true
    }

    func completeOnboarding(with profile: UserProfile) {
        self.profile = profile
        hasCompletedOnboarding = true
        persist()
    }

    func updateProfile(_ profile: UserProfile) {
        self.profile = profile
        persist()
    }

    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        persist()
    }

    func setAppleHealthSyncEnabled(_ enabled: Bool) {
        appleHealthSyncEnabled = enabled
        persist()
    }

    func setNutritionMacroDisplayStyle(_ style: NutritionMacroDisplayStyle) {
        nutritionMacroDisplayStyle = style
        persist()
    }

    func presentSyncFitPlusUpgrade(highlight: SyncFitPlusFeature = .general) {
        syncFitPlusUpgradeHighlight = highlight
        showingSyncFitPlusUpgrade = true
    }

    func presentAICoach() {
        showingAICoach = true
    }

    func completeProgramSetup(buildYourOwn: Bool = false) {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? context.fetch(descriptor).first else { return }
        settings.hasCompletedProgramSetup = true
        if buildYourOwn {
            settings.suppressDayTemplateAutoSeed = true
        }
        try? context.save()
        if buildYourOwn {
            selectedTab = .workouts
            shouldPresentScheduleSetup = true
        }
    }

    private func syncFromSettings() {
        hasCompletedOnboarding = settings.hasCompletedOnboarding
        profile = settings.profile
        appearance = settings.appearance
        appleHealthSyncEnabled = settings.appleHealthSyncEnabled
        nutritionMacroDisplayStyle = settings.nutritionMacroDisplayStyle
        restTimerSeconds = settings.restTimerSeconds
    }

    func setRestTimerSeconds(_ seconds: Int) {
        restTimerSeconds = max(seconds, 15)
        persist()
    }

    private func persist() {
        settings.hasCompletedOnboarding = hasCompletedOnboarding
        settings.profile = profile
        settings.appearance = appearance
        settings.appleHealthSyncEnabled = appleHealthSyncEnabled
        settings.nutritionMacroDisplayStyle = nutritionMacroDisplayStyle
        settings.restTimerSeconds = restTimerSeconds
        try? context.save()
    }

    private static func loadOrCreateSettings(context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let settings = AppSettings()
        context.insert(settings)
        try? context.save()
        return settings
    }

    static func preview() -> AppState {
        let container = try! SyncFitModelContainer.make(inMemory: true)
        let state = AppState(context: container.mainContext)
        state.hasCompletedOnboarding = true
        return state
    }
}
