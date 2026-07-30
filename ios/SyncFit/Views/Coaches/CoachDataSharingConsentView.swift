import SwiftUI
import FirebaseAuth

struct CoachDataSharingConsentView: View {
    let coach: CoachProfile
    var onComplete: () -> Void

    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var shareWorkouts = true
    @State private var shareNutrition = false
    @State private var shareProgress = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose what \(coach.name) can see:")
                        .font(.system(size: 15))
                        .foregroundStyle(CoachUIColor.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    permissionToggle(
                        title: "Workout history",
                        subtitle: "Logged sets, exercises, and training notes",
                        isOn: $shareWorkouts
                    )

                    permissionToggle(
                        title: "Nutrition logs",
                        subtitle: "Meals, macros, and calorie targets",
                        isOn: $shareNutrition
                    )

                    permissionToggle(
                        title: "Progress & photos",
                        subtitle: "Weight trend, PRs, and progress images",
                        isOn: $shareProgress
                    )

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CoachUIColor.errorRed)
                    }

                    Button("Connect →") {
                        confirmConnect()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(20)
            }
            .background(CoachUIColor.page)
            .navigationTitle("Connect with \(coach.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func permissionToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CoachUIColor.muted)
            }
        }
        .tint(CoachUIColor.accent)
        .padding(14)
        .background(CoachUIColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CoachUIColor.border, lineWidth: 0.5)
        )
    }

    private func confirmConnect() {
        guard Auth.auth().currentUser != nil else {
            errorMessage = "Sign in to connect with your coach."
            return
        }

        let clientName = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = clientName.isEmpty ? "SyncFit member" : clientName

        coachService.connectOptimistically(
            coach: coach,
            clientName: resolvedName,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress
        )

        onComplete()
        dismiss()
    }
}

struct CoachSharingManageView: View {
    let coach: CoachProfile

    @EnvironmentObject private var coachService: CoachService
    @Environment(\.dismiss) private var dismiss

    @State private var showingDisconnectConfirm = false

    private var connection: CoachClientConnection? {
        coachService.connection(with: coach.coachFirestoreID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Change what \(coach.name) can see at any time.")
                        .font(.system(size: 12))
                        .foregroundStyle(CoachUIColor.muted)

                    if connection != nil {
                        permissionToggle(
                            title: "Workout history",
                            subtitle: "Logged sets, exercises, and training notes",
                            isOn: permissionBinding(\.shareWorkouts)
                        )
                        permissionToggle(
                            title: "Nutrition logs",
                            subtitle: "Meals, macros, and calorie targets",
                            isOn: permissionBinding(\.shareNutrition)
                        )
                        permissionToggle(
                            title: "Progress and photos",
                            subtitle: "Weight trend, PRs, and progress images",
                            isOn: permissionBinding(\.shareProgress)
                        )
                    }

                    Button("Disconnect from \(coach.name)") {
                        showingDisconnectConfirm = true
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CoachUIColor.errorRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .background(CoachUIColor.page)
            .navigationTitle("Sharing with \(coach.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Disconnect from \(coach.name)?",
                isPresented: $showingDisconnectConfirm,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        if let connection {
                            try? await coachService.disconnectFromCoach(connection)
                        }
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll lose access to your data immediately.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func permissionToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CoachUIColor.muted)
            }
        }
        .tint(CoachUIColor.accent)
        .padding(14)
        .background(CoachUIColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CoachUIColor.border, lineWidth: 0.5)
        )
    }

    private func permissionBinding(_ keyPath: WritableKeyPath<CoachClientConnection, Bool>) -> Binding<Bool> {
        Binding(
            get: { coachService.connection(with: coach.coachFirestoreID)?[keyPath: keyPath] ?? false },
            set: { newValue in
                guard var connection = coachService.connection(with: coach.coachFirestoreID) else { return }
                connection[keyPath: keyPath] = newValue
                coachService.upsertClientConnectionForUI(connection)
                if coachService.clientCoachConnection?.documentID == connection.documentID {
                    coachService.clientCoachConnection = connection
                }
                Task {
                    try? await coachService.updateClientCoachPermissions(
                        for: connection,
                        shareWorkouts: connection.shareWorkouts,
                        shareNutrition: connection.shareNutrition,
                        shareProgress: connection.shareProgress
                    )
                }
            }
        )
    }
}

struct MyCoachCard: View {
    let coach: CoachProfile
    let connection: CoachClientConnection
    var hasUnreadMessage: Bool = false
    var onMessage: () -> Void
    var onOpenProfile: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpenProfile) {
                HStack(spacing: 12) {
                    CoachAvatarView(coach: coach, size: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(coach.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(coach.specialty)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Connected \(connection.connectedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onMessage) {
                HStack(spacing: 6) {
                    Text("Message →")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CoachUIColor.accent)
                    if hasUnreadMessage {
                        UnreadDotBadge(size: 8, offset: .zero)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct CoachSharingStatusSection: View {
    let coachName: String
    let connection: CoachClientConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sharing with \(coachName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            sharingRow("Workout history", enabled: connection.shareWorkouts)
            sharingRow("Nutrition logs", enabled: connection.shareNutrition)
            sharingRow("Progress & photos", enabled: connection.shareProgress)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CoachUIColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sharingRow(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(CoachUIColor.muted)
            Spacer()
            if enabled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(CoachUIColor.accent)
            } else {
                Text("—")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CoachUIColor.chipInactiveText)
            }
        }
    }
}
