import SwiftUI
import FirebaseAuth

struct CoachProfileScreen: View {
    let coach: CoachProfile
    var showsActionButtons: Bool = true
    var isPreviewMode: Bool = false
    var isProfileComplete: Bool = false
    var openManageSharingOnAppear: Bool = false
    var onEditProfile: (() -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var coachService: CoachService
    @Environment(\.dismiss) private var dismiss

    @State private var showingAllReviews = false
    @State private var showingManageSharing = false
    @State private var didOpenManageSharing = false
    @State private var activeChat: CoachChatRoute?
    @State private var signInPrompt: String?

    private var activeConnection: CoachClientConnection? {
        coachService.connection(with: coach.coachFirestoreID)
    }

    private var isConnected: Bool {
        activeConnection != nil
    }

    private var liveStripeChargesEnabled: Bool {
        coachService.liveStripeChargesEnabled[coach.coachFirestoreID] == true
    }

    private var checkoutState: CoachHireCheckoutState {
        coachService.hireCheckoutCoachUID == coach.coachFirestoreID
            ? coachService.hireCheckoutState
            : .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ratingRow
                aboutSection
                specialtyChips
                transformationGallery
                priceSection
                reviewsSection

                if showsActionButtons {
                    actionButtons
                }

                if isPreviewMode {
                    previewModeFooter
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(CoachUIColor.page)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Coaches")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(CoachUIColor.accent)
                }
            }
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
        .sheet(isPresented: $showingAllReviews) {
            CoachReviewsSheet(coach: coach)
        }
        .sheet(isPresented: $showingManageSharing) {
            CoachSharingManageView(coach: coach)
        }
        .onAppear {
            coachService.observeStripeAvailability(for: coach)
            checkConnectionStatus()
        }
        .onDisappear {
            coachService.stopObservingStripeAvailability(coachUID: coach.coachFirestoreID)
        }
        .onChange(of: coachService.clientCoachConnections) { _, _ in
            checkConnectionStatus()
        }
    }

    private func checkConnectionStatus() {
        Task {
            await coachService.refreshClientCoachConnection()
            if openManageSharingOnAppear, isConnected, !didOpenManageSharing {
                didOpenManageSharing = true
                showingManageSharing = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            CoachAvatarView(coach: coach, size: 88)
            Text(coach.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Text(coach.specialty)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CoachUIColor.muted)
                Text("✓ Verified")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoachUIColor.verified)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var ratingRow: some View {
        Group {
            if coach.reviewCount >= 1 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", coach.rating))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("· \(coach.reviewCount) review\(coach.reviewCount == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(CoachUIColor.muted)
                }
            } else {
                Text("No reviews yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CoachUIColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            CoachPageCard {
                Text(coach.bio)
                    .font(.system(size: 12))
                    .foregroundStyle(CoachUIColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var specialtyChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Specialties")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            CoachPageCard {
                CoachFlowLayout(spacing: 8) {
                    ForEach(coach.specialties, id: \.self) { specialty in
                        Text(specialty)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(CoachUIColor.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CoachUIColor.chipInactiveBackground)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(CoachUIColor.border, lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private var transformationGallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transformations")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            CoachPageCard {
                if coach.transformationPhotoFileNames.isEmpty {
                    Text("No transformation photos yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(CoachUIColor.muted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(coach.transformationPhotoFileNames, id: \.self) { fileName in
                                if let image = CoachPhotoStorage.loadTransformationImage(fileName: fileName, coachID: coach.id)
                                    ?? CoachPhotoStorage.loadImage(fileName: fileName, coachID: coach.id) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var priceSection: some View {
        CoachPageCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("$\(coach.pricePerMonth)/month")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(CoachUIColor.accent)
                Text(coach.availabilityBadge + (coach.location.isEmpty ? "" : " · \(coach.location)"))
                    .font(.system(size: 11))
                    .foregroundStyle(CoachUIColor.muted)
            }
        }
    }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reviews")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if coach.reviews.count > 3 {
                    Button("See all") { showingAllReviews = true }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CoachUIColor.accent)
                }
            }

            ForEach(coach.reviews.prefix(3)) { review in
                CoachPageCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(review.clientName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(String(format: "%.1f", review.rating))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.yellow)
                        }
                        Text(review.text)
                            .font(.system(size: 11))
                            .foregroundStyle(CoachUIColor.muted)
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if let signInPrompt {
                Text(signInPrompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachUIColor.errorRed)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if isConnected {
                HStack {
                    Spacer()
                    connectedStatusPill
                    Spacer()
                }

                Button("Message \(coach.name) →") {
                    openChat()
                }
                .buttonStyle(CoachPrimaryButtonStyle())

                Button("Manage sharing →") {
                    showingManageSharing = true
                }
                .buttonStyle(CoachTertiaryButtonStyle())
            } else {
                Button("Message coach") {
                    openChat()
                }
                .buttonStyle(CoachGhostButtonStyle())

                switch checkoutState {
                case .confirming:
                    checkoutConfirmingPanel
                case .confirmationTimedOut:
                    checkoutTimeoutFallbackPanel
                default:
                    hireCheckoutControls
                }
            }
        }
        .padding(.top, 8)
    }

    private var hireCheckoutControls: some View {
        VStack(spacing: 10) {
            if liveStripeChargesEnabled {
                Button(hireButtonTitle) {
                    Task { await coachService.beginCoachCheckout(for: coach) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isCheckoutInProgress || checkoutState == .confirmed)
            } else {
                Text("This coach is still completing setup.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachUIColor.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if checkoutState == .canceled {
                Text(CoachCheckoutConfirmationCopy.canceledMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachUIColor.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if case .failed(let message) = checkoutState,
                      message != "This coach is still completing setup." {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CoachUIColor.errorRed)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var checkoutConfirmingPanel: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(CoachUIColor.accent)
            Text(CoachCheckoutConfirmationCopy.confirmingTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 8)
    }

    private var checkoutTimeoutFallbackPanel: some View {
        VStack(spacing: 10) {
            Text(CoachCheckoutConfirmationCopy.timeoutMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CoachUIColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(CoachCheckoutConfirmationCopy.refreshTitle) {
                Task { await coachService.refreshHireCheckoutConfirmation() }
            }
            .buttonStyle(CoachTertiaryButtonStyle())
        }
        .padding(.vertical, 4)
    }

    private var hireButtonTitle: String {
        switch checkoutState {
        case .creatingCheckout: return "Starting checkout..."
        case .authenticating: return "Checkout open"
        case .confirming: return CoachCheckoutConfirmationCopy.confirmingTitle
        case .confirmed: return "Payment confirmed"
        default: return "Hire this coach →"
        }
    }

    private var isCheckoutInProgress: Bool {
        switch checkoutState {
        case .creatingCheckout, .authenticating, .confirming:
            return true
        default:
            return false
        }
    }

    private var connectedStatusPill: some View {
        let connectedDate = activeConnection?.connectedAt ?? .now
        let formatted = connectedDate.formatted(.dateTime.month(.abbreviated).day())
        return Text("✓ Connected since \(formatted)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CoachUIColor.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(red: 26 / 255, green: 58 / 255, blue: 26 / 255))
            .overlay(
                Capsule()
                    .strokeBorder(Color(red: 42 / 255, green: 58 / 255, blue: 42 / 255), lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .allowsHitTesting(false)
    }

    private var previewModeFooter: some View {
        VStack(spacing: 10) {
            Text(isProfileComplete ? "Your listing is live ✓" : "Complete your profile to go live")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isProfileComplete ? CoachUIColor.accent : CoachUIColor.muted)
                .frame(maxWidth: .infinity, alignment: .center)

            Button("Edit profile →") {
                onEditProfile?()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CoachUIColor.accent)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 8)
    }

    private func openChat() {
        guard let userId = Auth.auth().currentUser?.uid else {
            signInPrompt = "Sign in to message your coach."
            return
        }

        signInPrompt = nil
        let trimmedName = appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "SyncFit member" : trimmedName
        let coachId = coach.coachFirestoreID

        activeChat = CoachChatRoute(
            conversationId: CoachChatService.conversationId(userId: userId, coachId: coachId),
            coachId: coachId,
            coachName: coach.name,
            coachSpecialty: coach.specialty,
            userId: userId,
            userName: resolvedName
        )
    }
}

struct CoachPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding()
            .background(CoachUIColor.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CoachTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255).opacity(configuration.isPressed ? 0.8 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CoachGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(CoachUIColor.accent)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255).opacity(configuration.isPressed ? 0.8 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CoachUIColor.accent, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CoachReviewsSheet: View {
    let coach: CoachProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(coach.reviews) { review in
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.clientName)
                        .font(.headline)
                    Text(review.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(CoachUIColor.card)
            }
            .scrollContentBackground(.hidden)
            .background(CoachUIColor.page)
            .navigationTitle("Reviews")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
