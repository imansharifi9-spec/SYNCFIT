import SwiftUI
import FirebaseAuth
import FirebaseFunctions

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var chatService: CoachChatService
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @State private var showingSignOutConfirm = false
    @State private var showingEditProfile = false
    @State private var showingCoachLogin = false
    @State private var isUpdatingCoachPermissions = false
    @State private var showingDisconnectConfirm = false
    @State private var showingDeleteAccountFirstConfirm = false
    @State private var showingDeleteAccountFinalConfirm = false
    @State private var showingDeleteAccountError = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountErrorMessage: String?
    @State private var selectedCoachProfile: CoachProfile?
    @State private var activeChat: CoachChatRoute?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Workout")
                            .font(.headline)
                        Stepper(
                            "Rest timer: \(appState.restTimerSeconds)s",
                            value: Binding(
                                get: { appState.restTimerSeconds },
                                set: { appState.setRestTimerSeconds($0) }
                            ),
                            in: 30...300,
                            step: 15
                        )
                        Text("Countdown starts automatically after each saved set.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Routine Settings")
                            .font(.headline)
                        NavigationLink {
                            ScheduleSetupView()
                        } label: {
                            settingsLinkRow("Schedule", systemImage: "calendar")
                        }
                        .buttonStyle(.plain)
                        Button {
                            appState.presentSyncFitPlusUpgrade(highlight: .personalizedRoutines)
                        } label: {
                            settingsLinkRow("SyncFit+ Setup", systemImage: "sparkles")
                        }
                        .buttonStyle(.plain)
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Appearance")
                            .font(.headline)
                        Picker("Theme", selection: Binding(
                            get: { appState.appearance },
                            set: { appState.setAppearance($0) }
                        )) {
                            ForEach(AppAppearance.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Profile")
                                .font(.headline)
                            Spacer()
                            Button("Edit") {
                                showingEditProfile = true
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        settingsRow("Name", value: displayName)
                        settingsRow("Goal", value: appState.profile.goal.rawValue)
                        settingsRow("Experience", value: appState.profile.experienceLevel.rawValue)
                        settingsRow("Activity", value: appState.profile.activityLevel.rawValue)
                        settingsRow("Age", value: "\(appState.profile.age)")
                        settingsRow("Gender", value: appState.profile.gender.rawValue)
                        if appState.profile.measurementSystem == .imperial {
                            settingsRow("Height", value: "\(appState.profile.heightFeet) ft \(appState.profile.heightInches) in")
                            settingsRow("Weight", value: "\(SyncFitFormat.decimal(appState.profile.bodyWeightLbs)) lb")
                        } else {
                            settingsRow("Height", value: SyncFitFormat.decimal(appState.profile.heightCm) + " cm")
                            settingsRow("Weight", value: "\(SyncFitFormat.decimal(appState.profile.bodyWeightKg)) kg")
                        }
                        settingsRow("Maintenance", value: "\(CalorieCalculator.calculate(for: appState.profile).maintenance) cal")
                        settingsRow("Calorie target", value: "\(appState.profile.calorieTarget) cal")
                        settingsRow("Protein target", value: "\(appState.profile.proteinTarget)g")
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Subscription")
                            .font(.headline)
                        settingsRow("Plan", value: subscriptionManager.isSubscribed ? "SyncFit+" : "Free")
                        if subscriptionManager.hasPendingFirestoreSync {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Finishing setup…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(subscriptionManager.isSubscribed ? "Manage \(SyncFitPlusBrand.name)" : SyncFitPlusBrand.upgradeButton) {
                            appState.presentSyncFitPlusUpgrade()
                        }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }

                if coachService.isCoach {
                    SyncFitCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Coach")
                                .font(.headline)
                            HStack {
                                Text("Coach mode")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { coachService.isCoachModeActive },
                                        set: { active in
                                            coachService.setCoachModeActive(active)
                                            if !active {
                                                appState.selectedTab = .coaches
                                            }
                                        }
                                    )
                                )
                                .labelsHidden()
                                .tint(Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255))
                                .accessibilityIdentifier("coachModeToggle")
                            }
                            Text("Switch between your athlete app and the coach portal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if authManager.isAuthenticated {
                    SyncFitCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Coach")
                                .font(.headline)
                            Text("Have a SyncFit coach access code? Activate it to manage clients.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Enter coach access code") {
                                showingCoachLogin = true
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                if let connection = coachService.clientCoachConnection,
                   connection.isActive,
                   let hiredCoach = coachService.coach(with: connection.coachID)
                    ?? coachService.marketplaceCoaches.first(where: { $0.coachFirestoreID == connection.coachFirestoreID }) {
                    SyncFitCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("My coach")
                                .font(.headline)

                            MyCoachCard(
                                coach: hiredCoach,
                                connection: connection,
                                hasUnreadMessage: chatService.hasUnreadMessage(fromCoachId: hiredCoach.coachFirestoreID),
                                onMessage: { openCoachChat(coach: hiredCoach) },
                                onOpenProfile: { selectedCoachProfile = hiredCoach }
                            )

                            Divider()

                            Toggle("Workout history", isOn: coachPermissionBinding(\.shareWorkouts))
                                .disabled(isUpdatingCoachPermissions)
                            Toggle("Nutrition logs", isOn: coachPermissionBinding(\.shareNutrition))
                                .disabled(isUpdatingCoachPermissions)
                            Toggle("Progress & photos", isOn: coachPermissionBinding(\.shareProgress))
                                .disabled(isUpdatingCoachPermissions)

                            Button("Disconnect from coach", role: .destructive) {
                                showingDisconnectConfirm = true
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                AppleHealthSettingsSection()

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Nutrition")
                            .font(.headline)
                        NutritionDisplaySettingsSection()
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Data")
                            .font(.headline)
                        Label("You own your fitness data", systemImage: "lock.shield")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Export Data") {}
                            .buttonStyle(SecondaryButtonStyle())
                        Button(role: .destructive) {
                            showingDeleteAccountFirstConfirm = true
                        } label: {
                            HStack {
                                Text("Delete Account")
                                if isDeletingAccount {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDeletingAccount)
                        .accessibilityIdentifier("deleteAccountButton")
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Legal")
                            .font(.headline)
                        Link(destination: AppConfig.privacyPolicyURL) {
                            settingsLinkRow("Privacy Policy", systemImage: "hand.raised")
                        }
                        .buttonStyle(.plain)
                        Link(destination: AppConfig.termsOfServiceURL) {
                            settingsLinkRow("Terms of Service", systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                    }
                }

                SyncFitCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account")
                            .font(.headline)
                        Text("Sign out to switch accounts or return to the login screen.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Log Out", role: .destructive) {
                            showingSignOutConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(SyncFitTheme.background)
        .navigationTitle("Settings")
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
        .confirmationDialog(
            "Log out of SyncFit?",
            isPresented: $showingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                authManager.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in anytime. Workout and nutrition data for this account is removed from this device when you log out.")
        }
        .confirmationDialog(
            "Disconnect from \(coachService.clientCoachConnection?.coachName ?? "your coach")?",
            isPresented: $showingDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task {
                    try? await coachService.disconnectFromCoach()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will lose access to your data immediately.")
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteAccountFirstConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) {
                showingDeleteAccountFinalConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure? This cannot be undone. Your account and associated cloud data will be permanently deleted.")
        }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: $showingDeleteAccountFinalConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is your final confirmation. Account deletion cannot be reversed.")
        }
        .alert(
            "Couldn't delete account",
            isPresented: $showingDeleteAccountError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteAccountErrorMessage ?? DeleteAccountErrorMapper.genericFailureMessage)
        }
        .sheet(isPresented: $showingEditProfile) {
            EditProfileSheet(profile: appState.profile)
        }
        .sheet(isPresented: $showingCoachLogin) {
            CoachLoginView()
        }
        .task {
            await coachService.refreshClientCoachConnection()
        }
    }

    @MainActor
    private func deleteAccount() async {
        guard !isDeletingAccount else { return }
        guard FirebaseConfiguration.isConfigured else {
            deleteAccountErrorMessage = "Firebase is not configured. Add GoogleService-Info.plist to the SyncFit target."
            showingDeleteAccountError = true
            return
        }
        guard Auth.auth().currentUser != nil else {
            deleteAccountErrorMessage = "Sign in again, then try deleting your account."
            showingDeleteAccountError = true
            return
        }

        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            _ = try await Functions.functions()
                .httpsCallable("deleteUserAccount")
                .call([:] as [String: Any])

            // Wipe local cache for the deleted UID before sign-out so nothing is left orphaned.
            dataStore.clearAllLocalUserData()
            AuthenticationManager.clearLocalDataOwnerUserID()
            AuthenticationManager.clearLastAuthenticatedUserID()
            appState.resetProfileForUserSwitch()
            coachService.resetForUserSwitch()
            chatService.teardown()
            subscriptionManager.resetForLogout()
            authManager.signOut()
        } catch {
            deleteAccountErrorMessage = DeleteAccountErrorMapper.displayMessage(for: error)
            showingDeleteAccountError = true
        }
    }

    private func openCoachChat(coach: CoachProfile) {
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

    private func coachPermissionBinding(_ keyPath: WritableKeyPath<CoachClientConnection, Bool>) -> Binding<Bool> {
        Binding(
            get: { coachService.clientCoachConnection?[keyPath: keyPath] ?? false },
            set: { newValue in
                guard var connection = coachService.clientCoachConnection else { return }
                connection[keyPath: keyPath] = newValue
                coachService.clientCoachConnection = connection
                isUpdatingCoachPermissions = true
                Task {
                    try? await coachService.updateClientCoachPermissions(
                        shareWorkouts: connection.shareWorkouts,
                        shareNutrition: connection.shareNutrition,
                        shareProgress: connection.shareProgress
                    )
                    isUpdatingCoachPermissions = false
                }
            }
        )
    }

    private func settingsLinkRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SyncFitTheme.accent)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        let trimmed = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not set" : trimmed
    }

    private func settingsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppState.preview())
            .environmentObject(FitnessDataStore.preview())
            .environmentObject(HealthKitService.preview())
            .environmentObject(AuthenticationManager.previewAuthenticated())
    }
}
