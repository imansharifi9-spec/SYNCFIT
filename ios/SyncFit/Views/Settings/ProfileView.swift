import SwiftUI
import PhotosUI
import FirebaseAuth

struct ProfileAvatarView: View {
    var size: CGFloat = 36
    var userID: String = ""
    var photoFileName: String?
    var photoURL: String?

    @State private var resolvedImage: UIImage?

    var body: some View {
        Group {
            if let resolvedImage {
                Image(uiImage: resolvedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(SyncFitTheme.accentBright, SyncFitTheme.accentDark.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: "\(userID)|\(photoURL ?? "")|\(photoFileName ?? "")") {
            guard !userID.isEmpty else {
                resolvedImage = nil
                return
            }
            resolvedImage = await UserPhotoStorage.loadProfileImage(
                userID: userID,
                fileName: photoFileName,
                photoURL: photoURL
            )
        }
    }
}

/// Client avatar for coach-facing surfaces. Pass inline photo fields when already
/// available (e.g. live listener); otherwise set `subscribeToUpdates` to read
/// `users/{clientUserID}` reactively.
struct ClientProfileAvatarView: View {
    let clientUserID: String
    var photoFileName: String?
    var photoURL: String?
    var size: CGFloat = 40
    var subscribeToUpdates: Bool = false

    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @State private var subscribedFileName: String?
    @State private var subscribedURL: String?

    private var resolvedFileName: String? { photoFileName ?? subscribedFileName }
    private var resolvedURL: String? { photoURL ?? subscribedURL }

    var body: some View {
        ProfileAvatarView(
            size: size,
            userID: clientUserID,
            photoFileName: resolvedFileName,
            photoURL: resolvedURL
        )
        .task(id: subscriptionKey) {
            guard subscribeToUpdates, firestore.isAvailable, !clientUserID.isEmpty else { return }
            let registration = firestore.observeClientProfile(
                clientUserID: clientUserID,
                onChange: { profile in
                    Task { @MainActor in
                        subscribedFileName = profile.photoFileName
                        subscribedURL = profile.photoURL
                    }
                }
            )
            defer { registration?.remove() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private var subscriptionKey: String {
        "\(clientUserID)|\(subscribeToUpdates)"
    }
}

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var chatService: CoachChatService
    @EnvironmentObject private var firestore: FirestoreDatabaseManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedCoachProfile: CoachProfile?
    @State private var activeChat: CoachChatRoute?
    @State private var profilePickerItem: PhotosPickerItem?
    @State private var showingProfilePhotoPicker = false

    private var userAuthUID: String {
        Auth.auth().currentUser?.uid ?? ""
    }

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
                                hasUnreadMessage: chatService.hasUnreadMessage(fromCoachId: coach.coachFirestoreID),
                                onMessage: { openChat(with: coach, connection: connection) },
                                onOpenProfile: { selectedCoachProfile = coach }
                            )
                        }
                    }
                }

                SyncFitCard {
                    VStack(spacing: 14) {
                        profilePhotoSection

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
                        .accessibilityIdentifier("profileSettingsButton")
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

    private var profilePhotoSection: some View {
        VStack(spacing: 8) {
            Button {
                showingProfilePhotoPicker = true
            } label: {
                ProfileAvatarView(
                    size: 72,
                    userID: userAuthUID,
                    photoFileName: appState.profile.photoFileName,
                    photoURL: appState.profile.photoURL
                )
            }
            .buttonStyle(.plain)
            .disabled(userAuthUID.isEmpty)

            Text("Tap to upload photo")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .photosPicker(isPresented: $showingProfilePhotoPicker, selection: $profilePickerItem, matching: .images)
        .onChange(of: profilePickerItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        #if DEBUG
                        print("[UserPhoto] Picker produced no image data")
                        #endif
                        return
                    }
                    guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
                        #if DEBUG
                        print("[UserPhoto] Upload skipped — not signed in")
                        #endif
                        return
                    }

                    let fileName = UserPhotoStorage.profileFileName
                    try UserPhotoStorage.saveJPEG(from: image, fileName: fileName, userID: uid)
                    await MainActor.run {
                        var updated = appState.profile
                        updated.photoFileName = fileName
                        appState.updateProfile(updated)
                        profilePickerItem = nil
                    }

                    let downloadURL = try await UserPhotoStorage.uploadProfilePhoto(
                        image: image,
                        userAuthUID: uid
                    )

                    await MainActor.run {
                        var updated = appState.profile
                        updated.photoURL = downloadURL
                        appState.updateProfile(updated)
                    }

                    try await firestore.saveUserProfile(
                        appState.profile,
                        hasCompletedOnboarding: appState.hasCompletedOnboarding
                    )
                    #if DEBUG
                    print("[UserPhoto] Profile photo saved + synced photoURL")
                    #endif
                } catch {
                    #if DEBUG
                    print("[UserPhoto] Profile photo save FAILED: \(error)")
                    #endif
                    await MainActor.run { profilePickerItem = nil }
                }
            }
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
        let workoutProgress = dataStore.workoutGoalMet(on: .now) ? 1.0 : 0.0
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
