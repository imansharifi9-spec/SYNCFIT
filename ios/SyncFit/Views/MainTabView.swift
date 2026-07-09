import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var coachService: CoachService

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
                .tabItem { Label("Coaches", systemImage: "person.2.fill") }
                .tag(AppTab.coaches)
        }
        .tint(SyncFitTheme.accent)
    }
}
