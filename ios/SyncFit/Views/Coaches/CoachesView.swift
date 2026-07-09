import SwiftUI
import SafariServices
import FirebaseAuth

struct CoachesView: View {
    @EnvironmentObject private var dataStore: FitnessDataStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var coachService: CoachService

    @State private var searchText = ""
    @State private var showingCoachLogin = false
    @State private var showingGoalMatchSheet = false
    @State private var selectedCoach: CoachProfile?
    @State private var manageSharingCoachId: UUID?
    @State private var activeChat: CoachChatRoute?

    private var allCoaches: [CoachProfile] {
        var merged = dataStore.coaches
        for coach in coachService.marketplaceCoaches where coach.isLive && coach.isListed {
            if let index = merged.firstIndex(where: { $0.id == coach.id }) {
                let existing = merged[index]
                merged[index] = CoachProfile(
                    id: coach.id,
                    name: coach.name,
                    specialty: coach.specialty,
                    pricePerMonth: coach.pricePerMonth,
                    isOnline: coach.isOnline,
                    rating: coach.rating,
                    bio: coach.bio,
                    clientCount: coach.clientCount > 0 ? coach.clientCount : existing.clientCount,
                    reviewCount: max(coach.reviewCount, existing.reviewCount),
                    isVerified: coach.isVerified,
                    availability: coach.availability,
                    location: coach.location.isEmpty ? existing.location : coach.location,
                    specialties: coach.specialties.isEmpty ? existing.specialties : coach.specialties,
                    reviews: coach.reviews.isEmpty ? existing.reviews : coach.reviews,
                    photoFileName: coach.photoFileName ?? existing.photoFileName,
                    transformationPhotoFileNames: coach.transformationPhotoFileNames.isEmpty
                        ? existing.transformationPhotoFileNames
                        : coach.transformationPhotoFileNames,
                    isLive: coach.isLive,
                    isListed: coach.isListed,
                    coachUserID: coach.coachUserID ?? existing.coachUserID
                )
            } else if !merged.contains(where: { $0.name == coach.name }) {
                merged.append(coach)
            }
        }
        return merged
    }

    private var connectedCoachItems: [(connection: CoachClientConnection, coach: CoachProfile)] {
        coachService.clientCoachConnections.compactMap { connection in
            guard connection.isActive,
                  let coach = coachService.coachProfile(for: connection, localCoaches: allCoaches) else {
                return nil
            }
            return (connection, coach)
        }
    }

    private var coaches: [CoachProfile] {
        let filtered = coachService.filteredCoaches(searchText: searchText, coaches: allCoaches)
        let connectedIDs = coachService.connectedCoachFirestoreIDs
        return filtered.filter { !connectedIDs.contains($0.coachFirestoreID) }
    }

    private var activeProgramName: String {
        dataStore.displaySessionName(for: .now)
            ?? dataStore.activeDayTemplate(for: .now)?.displayName
            ?? dataStore.expectedSplitKind(for: .now)?.displayName
            ?? "training"
    }

    private var todayRoutineKind: WorkoutScheduleKind? {
        dataStore.activeDayTemplate(for: .now) ?? dataStore.expectedSplitKind(for: .now)
    }

    private var sectionLabel: String {
        if coachService.aiMatchFilterActive || coachService.activeFilter != .all || !searchText.isEmpty {
            return "BEST MATCHES FOR YOU"
        }
        return "FEATURED COACHES"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if !connectedCoachItems.isEmpty {
                        myCoachSection
                    }
                    searchBar
                    filterChips
                    aiMatchCard
                    sectionLabelView
                    coachList
                    coachLoginLink
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(CoachUIColor.page)
            .navigationBarHidden(true)
            .onAppear {
                coachService.seedFromLocalStore(dataStore.coaches)
                Task { await coachService.refreshClientCoachConnection() }
                #if DEBUG
                Task {
                    await coachService.seedDevCoachCodeIfNeeded()
                    await coachService.syncCoachStatusFromCloud(
                        profileName: appState.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                #endif
            }
            .sheet(isPresented: $showingCoachLogin) {
                CoachLoginView()
            }
            .sheet(isPresented: $showingGoalMatchSheet) {
                CoachGoalMatchSheet(
                    programName: activeProgramName,
                    goal: appState.profile.goal
                ) {
                    coachService.applyAIMatch(
                        goal: appState.profile.goal,
                        routineKind: todayRoutineKind
                    )
                    showingGoalMatchSheet = false
                }
            }
            .navigationDestination(item: $selectedCoach) { coach in
                CoachProfileScreen(
                    coach: coach,
                    openManageSharingOnAppear: manageSharingCoachId == coach.id
                )
                .onAppear { manageSharingCoachId = nil }
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
        }
    }

    private var myCoachSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MY COACH")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255))
                .tracking(0.8)

            ForEach(connectedCoachItems, id: \.connection.documentID) { item in
                MyCoachTabCard(
                    coach: item.coach,
                    connection: item.connection,
                    onMessage: { openChat(with: item.coach) },
                    onManage: {
                        manageSharingCoachId = item.coach.id
                        selectedCoach = item.coach
                    },
                    onOpenProfile: { selectedCoach = item.coach }
                )
            }
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coaches")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("Verified by SyncFit")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CoachUIColor.muted)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(CoachUIColor.muted)
            TextField("Search by name or goal...", text: $searchText)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CoachUIColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CoachUIColor.border, lineWidth: 0.5)
        )
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CoachMarketplaceFilter.allCases) { filter in
                    Button {
                        if filter == .nearMe {
                            coachService.requestNearMeFilter()
                        } else {
                            coachService.activeFilter = filter
                            coachService.clearAIMatch()
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: coachService.activeFilter == filter ? .bold : .medium))
                            .foregroundStyle(coachService.activeFilter == filter ? .black : CoachUIColor.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                coachService.activeFilter == filter
                                    ? CoachUIColor.chipActive
                                    : Color.clear
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        coachService.activeFilter == filter ? CoachUIColor.chipActive : CoachUIColor.chipBorder,
                                        lineWidth: 0.5
                                    )
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var aiMatchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✦ AI MATCH")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(CoachUIColor.accent)
                .textCase(.uppercase)
                .tracking(0.6)

            Text("Based on your \(activeProgramName) program and \(appState.profile.goal.rawValue.lowercased()), we recommend finding a specialist coach.")
                .font(.system(size: 12))
                .foregroundStyle(CoachUIColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Find my coach →") {
                showingGoalMatchSheet = true
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(CoachUIColor.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 15 / 255, green: 26 / 255, blue: 15 / 255))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(red: 30 / 255, green: 58 / 255, blue: 30 / 255), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sectionLabelView: some View {
        Text(sectionLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(CoachUIColor.section)
            .tracking(0.8)
            .padding(.top, 4)
    }

    private var coachList: some View {
        LazyVStack(spacing: 8) {
            ForEach(coaches) { coach in
                Button {
                    selectedCoach = coach
                } label: {
                    CoachMarketplaceCard(coach: coach)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var coachLoginLink: some View {
        Button("Are you a coach? Log in →") {
            showingCoachLogin = true
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(CoachUIColor.footer)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func openChat(with coach: CoachProfile) {
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
}

private struct MyCoachTabCard: View {
    let coach: CoachProfile
    let connection: CoachClientConnection
    var onMessage: () -> Void
    var onManage: () -> Void
    var onOpenProfile: () -> Void

    private var connectedLabel: String {
        "✓ Connected \(connection.connectedAt.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpenProfile) {
                HStack(spacing: 10) {
                    CoachAvatarView(coach: coach, size: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(coach.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("\(coach.specialty) · $\(coach.pricePerMonth)/mo")
                            .font(.system(size: 10))
                            .foregroundStyle(CoachUIColor.muted)
                            .lineLimit(1)
                        Text(connectedLabel)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(red: 74 / 255, green: 138 / 255, blue: 90 / 255))
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button(action: onMessage) {
                    Text("Message →")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CoachUIColor.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 26 / 255, green: 58 / 255, blue: 26 / 255))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onManage) {
                    Text("Manage")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(red: 102 / 255, green: 102 / 255, blue: 102 / 255))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(red: 15 / 255, green: 26 / 255, blue: 15 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(red: 30 / 255, green: 58 / 255, blue: 30 / 255), lineWidth: 0.5)
        )
    }
}

struct CoachMarketplaceCard: View {
    let coach: CoachProfile

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoachAvatarView(coach: coach, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(coach.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("✓ Verified")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(CoachUIColor.verified)
                }

                Text(coach.marketplaceCardSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CoachUIColor.muted)
                    .lineLimit(1)

                HStack {
                    Text("$\(coach.pricePerMonth)/mo")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(CoachUIColor.accent)

                    Text(coach.availabilityBadge)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CoachUIColor.muted)

                    Spacer()

                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", coach.rating))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CoachUIColor.border, lineWidth: 0.5)
        )
    }
}

struct CoachAvatarView: View {
    let coach: CoachProfile
    var size: CGFloat = 40

    private var backgroundColor: Color {
        switch coach.specialty.lowercased() {
        case let s where s.contains("muscle"): return Color(red: 0.35, green: 0.2, blue: 0.45)
        case let s where s.contains("fat"), let s where s.contains("weight"): return Color(red: 0.2, green: 0.35, blue: 0.45)
        case let s where s.contains("power"): return Color(red: 0.45, green: 0.25, blue: 0.2)
        default: return Color(red: 0.25, green: 0.35, blue: 0.25)
        }
    }

    var body: some View {
        Group {
            if let fileName = coach.photoFileName,
               let image = CoachPhotoStorage.loadImage(fileName: fileName, coachID: coach.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(coach.initials)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(backgroundColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct CoachGoalMatchSheet: View {
    let programName: String
    let goal: FitnessGoal
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("We'll match you with coaches who specialize in \(goal.rawValue.lowercased()) and align with your \(programName).")
                    .font(.system(size: 14))
                    .foregroundStyle(CoachUIColor.muted)

                Button("Show best matches") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())

                Spacer()
            }
            .padding(20)
            .background(CoachUIColor.page)
            .navigationTitle("Find my coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    CoachesView()
        .environmentObject(FitnessDataStore.preview())
        .environmentObject(AppState.preview())
        .environmentObject(CoachService(context: try! SyncFitModelContainer.make(inMemory: true).mainContext))
}
