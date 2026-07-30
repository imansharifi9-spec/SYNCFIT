import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var dataStore: FitnessDataStore

    var body: some View {
        Group {
            if !authManager.hasResolvedInitialAuthState || appState.isRestoringSession {
                // Hold on loading until auth resolves AND cloud onboarding state is restored.
                // Prevents a flash of OnboardingView / ProgramOnboardingFlow for returning users.
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

    private var launchLoadingView: some View {
        ZStack {
            SyncFitTheme.background.ignoresSafeArea()
            ProgressView()
        }
    }
}
