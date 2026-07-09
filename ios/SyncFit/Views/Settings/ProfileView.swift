import SwiftUI
import FirebaseAuth

struct ProfileAvatarView: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.palette)
            .foregroundStyle(SyncFitTheme.accentBright, SyncFitTheme.accentDark.opacity(0.35))
            .frame(width: size, height: size)
    }
}

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedCoachProfile: CoachProfile?
    @State private var activeChat: CoachChatRoute?

    private var hiredCoach: CoachProfile? {
        guard let connection = coachService.clientCoachConnection, connection.isActive else { return nil }
        return coachService.coach(with: connection.coachID)
            ?? coachService.marketplaceCoaches.first(where: { $0.coachFirestoreID == connection.coachFirestoreID })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let connection = coachService.clientCoachConnection,
                   connection.isActive,
                   let coach = hiredCoach {
                    SyncFitCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("My coach")
                                .font(.headline)

                            MyCoachCard(
                                coach: coach,
                                connection: connection,
                                onMessage: { openChat(with: coach, connection: connection) },
                                onOpenProfile: { selectedCoachProfile = coach }
                            )
                        }
                    }
                }

                SyncFitCard {
                    VStack(spacing: 14) {
                        ProfileAvatarView(size: 72)

                        Text(displayName)
                            .font(.title2.bold())
                            .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))

                        HStack(spacing: 0) {
                            profileStat(value: "\(workoutsThisWeek)", label: "Workouts\nthis week")
                            Divider().frame(height: 36)
                            profileStat(value: missionPercentText, label: "Today's\nmission")
                            Divider().frame(height: 36)
                            profileStat(value: "\(dataStore.workouts.count)", label: "Total\nlogged")
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("About Athlete")
                                .font(.headline)
                                .foregroundStyle(SyncFitTheme.itemHeading)

                            aboutRow("Goal", value: appState.profile.goal.rawValue)
                            aboutRow("Experience", value: appState.profile.experienceLevel.rawValue)
                            aboutRow("Age", value: "\(appState.profile.age)")
                            aboutRow("Gender", value: appState.profile.gender.rawValue)
                            if appState.profile.measurementSystem == .imperial {
                                aboutRow("Height", value: "\(appState.profile.heightFeet) ft \(appState.profile.heightInches) in")
                                aboutRow("Weight", value: "\(SyncFitFormat.decimal(appState.profile.bodyWeightLbs)) lb")
                            } else {
                                aboutRow("Height", value: SyncFitFormat.decimal(appState.profile.heightCm) + " cm")
                                aboutRow("Weight", value: "\(SyncFitFormat.decimal(appState.profile.bodyWeightKg)) kg")
                            }
                            aboutRow("Daily calories", value: "\(appState.profile.calorieTarget)")
                            aboutRow("Protein target", value: "\(appState.profile.proteinTarget)g")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account")
                            .font(.headline)

                        NavigationLink {
                            SettingsView()
                        } label: {
                            HStack {
                                Label("Settings", systemImage: "gearshape")
                                    .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(SyncFitTheme.background)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedCoachProfile) { coach in
            CoachProfileScreen(coach: coach)
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
        .task {
            await coachService.refreshClientCoachConnection()
            await refreshProfileFromCloud()
        }
    }

    private func openChat(with coach: CoachProfile, connection: CoachClientConnection) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let trimmedName = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "SyncFit member" : trimmedName

        activeChat = CoachChatRoute(
            conversationId: CoachChatService.conversationId(userId: userId, coachId: coach.coachFirestoreID),
            coachId: coach.coachFirestoreID,
            coachName: coach.name,
            coachSpecialty: coach.specialty,
            userId: userId,
            userName: resolvedName
        )
    }

    private func refreshProfileFromCloud() async {
        guard firestore.isAvailable,
              let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let cloud = try await firestore.fetchUserProfile()
            if !cloud.ownerUserID.isEmpty, cloud.ownerUserID != uid {
                return
            }
            if cloud.hasCompletedOnboarding {
                appState.applyCloudProfile(cloud)
            }
        } catch {
            // Keep current local profile if refresh fails.
        }
    }

    private var displayName: String {
        let trimmed = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Athlete Name" : trimmed
    }

    private var workoutsThisWeek: Int {
        let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return dataStore.workouts.filter { $0.date >= weekStart }.count
    }

    private var missionPercentText: String {
        let proteinTarget = max(appState.profile.proteinTarget, 1)
        let proteinProgress = min(Double(dataStore.todaysProtein) / Double(proteinTarget), 1)
        let workoutProgress = dataStore.hasWorkoutToday ? 1.0 : 0.0
        let percent = Int((((proteinProgress + workoutProgress) / 2) * 100).rounded())
        return "\(percent)%"
    }

    private func profileStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(SyncFitTheme.itemHeading)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))
        }
        .font(.subheadline)
    }
}

#Preview {
    NavigationStack {
        ProfileView()
            .environmentObject(AppState.preview())
            .environmentObject(FitnessDataStore.preview())
    }
}
