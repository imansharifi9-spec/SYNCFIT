import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var dataStore: FitnessDataStore

    var body: some View {
        Group {
            if shouldHoldLaunchLoading {
                // Hold on loading until auth resolves AND cloud onboarding state is restored.
                // Prevents a flash of OnboardingView / ProgramOnboardingFlow for returning users.
                // Also covers the cold-launch gap where auth is ready but syncUserSession has
                // not started yet — otherwise Messages attaches and sticks on Code=7.
                launchLoadingView
            } else if !authManager.isAuthenticated {
                AuthView()
            } else if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if dataStore.needsProgramOnboarding {
                ProgramOnboardingFlow(onFinish: {})
            } else {
                MainTabView()
            }
        }
        .preferredColorScheme(appState.appearance.colorScheme)
        .task {
            FirebaseConfiguration.configureIfNeeded()
            authManager.startIfNeeded()
        }
    }

    /// Auth still resolving, cloud restore in progress, or authenticated but the
    /// first session sync of this launch has not finished yet.
    private var shouldHoldLaunchLoading: Bool {
        if !authManager.hasResolvedInitialAuthState { return true }
        if appState.isRestoringSession { return true }
        if authManager.isAuthenticated && !appState.hasFinishedSessionRestoreThisLaunch {
            return true
        }
        return false
    }

    private var launchLoadingView: some View {
        ZStack {
            SyncFitTheme.background.ignoresSafeArea()
            ProgressView()
        }
    }
}
