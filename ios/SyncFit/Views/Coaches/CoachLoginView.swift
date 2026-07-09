import SwiftUI
import FirebaseAuth

struct CoachLoginView: View {
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var accessCode = ""
    @State private var errorMessage: String?
    @State private var isActivating = false
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Coach access")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)

                    Text("Enter the access code provided by SyncFit")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CoachUIColor.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                TextField("XXXX-XXXXX", text: $accessCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($isCodeFocused)
                    .tracking(3.2)
                    .padding()
                    .background(CoachUIColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                errorMessage == nil ? CoachUIColor.border : Color.red.opacity(0.6),
                                lineWidth: 0.5
                            )
                    )
                    .onChange(of: accessCode) { _, newValue in
                        let filtered = newValue.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                        if filtered != newValue {
                            accessCode = filtered
                        }
                        errorMessage = nil
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                }

                if coachService.isCoach {
                    Button("Enter coach portal →") {
                        coachService.enterCoachMode()
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CoachUIColor.accent)
                }

                Button(isActivating ? "Activating..." : "Activate →") {
                    Task { await activate() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isActivating || accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 8)

                Spacer()
            }
            .padding(20)
            .background(CoachUIColor.page)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                isCodeFocused = true
                #if DEBUG
                Task {
                    await coachService.seedDevCoachCodeIfNeeded()
                    await coachService.syncCoachStatusFromCloud(
                        profileName: appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                #endif
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func activate() async {
        guard authManager.isAuthenticated, Auth.auth().currentUser != nil else {
            errorMessage = "Sign in to your SyncFit account first, then enter your coach code."
            return
        }

        isActivating = true
        defer { isActivating = false }

        let profileName = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await coachService.activateCoachCode(accessCode, profileName: profileName)

        switch result {
        case .success:
            dismiss()
        case .notSignedIn:
            errorMessage = "Sign in to your SyncFit account first, then enter your coach code."
        case .invalidCode:
            errorMessage = "Invalid or expired code. Contact SyncFit for access."
        case .revoked:
            errorMessage = "This code has been revoked. Contact SyncFit."
        case .unavailable:
            errorMessage = "Couldn't verify your code. Check your connection."
        }
    }
}
