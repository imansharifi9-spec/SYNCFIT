import SwiftUI
import PhotosUI
import UIKit
import FirebaseAuth

enum CoachPortalTab: Hashable {
    case profile
    case clients
    case messages
    case preview
}

struct CoachMainTabView: View {
    @EnvironmentObject private var chatService: CoachChatService
    @EnvironmentObject private var coachService: CoachService
    @State private var selectedTab: CoachPortalTab = .profile

    private var coachParticipantId: String {
        // Always prefer live Auth uid. Never fall back to portalProfile.id.uuidString —
        // that placeholder would wipe the shared conversations listener.
        if let uid = Auth.auth().currentUser?.uid,
           CoachChatService.isValidConversationParticipantId(uid) {
            return uid
        }
        return coachService.portalProfile.coachUserID
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            CoachProfileEditorTab()
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(CoachPortalTab.profile)

            CoachClientsTab()
                .tabItem { Label("Clients", systemImage: "person.3.fill") }
                .tag(CoachPortalTab.clients)

            CoachMessagesTab()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(chatService.hasUnreadMessages ? "" : nil)
                .tag(CoachPortalTab.messages)

            CoachPreviewTab(selectedTab: $selectedTab)
                .tabItem { Label("Preview", systemImage: "eye.fill") }
                .tag(CoachPortalTab.preview)
        }
        .tint(CoachUIColor.accent)
        .onAppear {
            if CoachChatService.isValidConversationParticipantId(coachParticipantId) {
                chatService.startUnreadMonitoring(for: coachParticipantId)
            }
        }
    }
}

// MARK: - Profile editor

struct CoachProfileEditorTab: View {
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var appState: AppState
    @State private var profilePickerItem: PhotosPickerItem?
    @State private var showingProfilePhotoPicker = false
    @State private var showingTransformSourcePicker = false
    @State private var showingTransformCamera = false
    @State private var showingTransformLibrary = false
    @State private var transformPickerItem: PhotosPickerItem?
    @State private var capturedTransformImage: UIImage?

    private var profile: Binding<CoachPortalProfile> {
        Binding(
            get: { coachService.portalProfile },
            set: { coachService.portalProfile = $0 }
        )
    }

    private var transformationRecords: [CoachTransformationPhotoRecord] {
        let stored = coachService.portalProfile.transformationPhotos
        if !stored.isEmpty { return stored }
        return CoachPhotoStorage.loadTransformationRecords(for: coachService.portalProfile.id)
    }

    private var transformationSlotCount: Int {
        transformationRecords.isEmpty ? 3 : 6
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profilePhotoSection

                    CoachProfileSection(title: "Name") {
                        TextField("Your name", text: profile.name)
                            .foregroundStyle(.white)
                    }

                    specialtySection

                    CoachProfileSection(title: "About") {
                        CoachAboutEditor(text: profile.about)
                    }

                    CoachProfileSection(title: "Rate") {
                        CoachRateField(ratePerMonth: profile.ratePerMonth)
                    }

                    availabilitySection

                    if profile.wrappedValue.availability.supportsInPerson {
                        CoachProfileSection(title: "Location") {
                            TextField("City, State", text: profile.location)
                                .foregroundStyle(.white)
                        }
                    }

                    transformationSection
                    testimonialsSection
                    myRoutinesSection

                    CoachSaveProfileButton()

                    Button("Exit coach mode →") {
                        coachService.exitCoachMode()
                        appState.selectedTab = .coaches
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CoachUIColor.footer)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CoachUIColor.page)
            .navigationTitle(profile.wrappedValue.name.isEmpty ? "Edit Profile" : profile.wrappedValue.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CoachUIColor.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                syncTransformationRecordsFromDisk()
            }
            .confirmationDialog("Add transformation photo", isPresented: $showingTransformSourcePicker, titleVisibility: .visible) {
                Button("Take photo") { showingTransformCamera = true }
                Button("Choose from library") { showingTransformLibrary = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showingTransformLibrary, selection: $transformPickerItem, matching: .images)
            .fullScreenCover(isPresented: $showingTransformCamera) {
                CoachCameraCapture(image: $capturedTransformImage)
                    .ignoresSafeArea()
            }
            .onChange(of: transformPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            saveTransformationPhoto(image)
                            transformPickerItem = nil
                        }
                    }
                }
            }
            .onChange(of: capturedTransformImage) { _, image in
                guard let image else { return }
                saveTransformationPhoto(image)
                capturedTransformImage = nil
            }
        }
    }

    private var profilePhotoSection: some View {
        VStack(spacing: 8) {
            Button {
                showingProfilePhotoPicker = true
            } label: {
                Group {
                    if let fileName = profile.wrappedValue.photoFileName,
                       let image = CoachPhotoStorage.loadImage(fileName: fileName, coachID: profile.wrappedValue.id) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Text(profile.wrappedValue.name.coachInitials)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(CoachUIColor.card)
                    }
                }
                .frame(width: 70, height: 70)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text("Tap to upload photo")
                .font(.system(size: 10))
                .foregroundStyle(CoachUIColor.muted)
        }
        .frame(maxWidth: .infinity)
        .photosPicker(isPresented: $showingProfilePhotoPicker, selection: $profilePickerItem, matching: .images)
        .onChange(of: profilePickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let fileName = "profile.jpg"
                    try? CoachPhotoStorage.saveJPEG(from: image, fileName: fileName, coachID: profile.wrappedValue.id)
                    await MainActor.run {
                        coachService.portalProfile.photoFileName = fileName
                        profilePickerItem = nil
                    }
                }
            }
        }
    }

    private var specialtySection: some View {
        CoachProfileSection(title: "Specialty") {
            CoachFlowLayout(spacing: 8) {
                ForEach(CoachPortalSpecialty.allCases) { specialty in
                    let selected = profile.wrappedValue.specialties.contains(specialty.rawValue)
                    CoachSpecialtyChip(
                        title: specialty.rawValue,
                        isSelected: selected
                    ) {
                        toggleSpecialty(specialty.rawValue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var availabilitySection: some View {
        CoachProfileSection(title: "Availability") {
            Picker("Availability", selection: profile.availability) {
                ForEach(CoachAvailability.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var transformationSection: some View {
        CoachProfileSection(
            title: "Transformation photos",
            subtitle: "Before and after client results"
        ) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
            let records = transformationRecords

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<transformationSlotCount, id: \.self) { index in
                    if index < records.count {
                        let record = records[index]
                        if let image = CoachPhotoStorage.loadTransformationImage(
                            fileName: record.fileName,
                            coachID: profile.wrappedValue.id
                        ) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    } else {
                        Button {
                            showingTransformSourcePicker = true
                        } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    CoachUIColor.border,
                                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                                )
                                .frame(height: 70)
                                .overlay {
                                    Text("+ Add")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(CoachUIColor.muted)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func syncTransformationRecordsFromDisk() {
        let records = CoachPhotoStorage.loadTransformationRecords(for: coachService.portalProfile.id)
        if !records.isEmpty {
            coachService.portalProfile.transformationPhotos = records
            coachService.portalProfile.transformationPhotoFileNames = records.map(\.fileName)
        }
    }

    private func saveTransformationPhoto(_ image: UIImage) {
        guard transformationRecords.count < 6 else { return }
        if let record = try? CoachPhotoStorage.saveTransformationPhoto(
            from: image,
            coachID: coachService.portalProfile.id
        ) {
            coachService.portalProfile.transformationPhotos.append(record)
            coachService.portalProfile.transformationPhotoFileNames.append(record.fileName)
        }
    }

    private var testimonialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Client referrals")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            if !coachService.portalProfile.testimonials.isEmpty {
                List {
                    ForEach(coachService.portalProfile.testimonials.indices, id: \.self) { index in
                        CoachTestimonialCard(
                            testimonial: testimonialBinding(at: index)
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                coachService.portalProfile.testimonials.remove(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: testimonialListHeight)
            }

            if coachService.portalProfile.testimonials.count < 5 {
                Button("Add testimonial") {
                    coachService.portalProfile.testimonials.append(CoachTestimonial())
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CoachUIColor.accent)
            }
        }
    }

    private var myRoutinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My Routines")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Text("Reusable workout templates you can send to any client.")
                .font(.system(size: 11))
                .foregroundStyle(CoachUIColor.muted)

            NavigationLink {
                CoachRoutineLibraryView()
            } label: {
                HStack {
                    Image(systemName: "dumbbell")
                    Text("Manage routine library")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(CoachUIColor.accent)
                .padding(14)
                .background(CoachUIColor.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var testimonialListHeight: CGFloat {
        CGFloat(coachService.portalProfile.testimonials.count) * 128
    }

    private func testimonialBinding(at index: Int) -> Binding<CoachTestimonial> {
        Binding(
            get: { coachService.portalProfile.testimonials[index] },
            set: { coachService.portalProfile.testimonials[index] = $0 }
        )
    }

    private func toggleSpecialty(_ specialty: String) {
        if let index = coachService.portalProfile.specialties.firstIndex(of: specialty) {
            coachService.portalProfile.specialties.remove(at: index)
        } else {
            coachService.portalProfile.specialties.append(specialty)
        }
    }
}

// MARK: - Clients

struct CoachClientsTab: View {
    @EnvironmentObject private var coachService: CoachService
    @State private var selectedConnection: CoachClientConnection?

    var body: some View {
        NavigationStack {
            Group {
                if coachService.clientConnections.isEmpty {
                    VStack {
                        Spacer()
                        Text("No clients yet. Share your profile to start connecting.")
                            .font(.system(size: 13))
                            .foregroundStyle(CoachUIColor.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                } else {
                    List(coachService.clientConnections) { connection in
                        Button {
                            selectedConnection = connection
                        } label: {
                            CoachClientConnectionCard(connection: connection)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(CoachUIColor.card)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(CoachUIColor.page)
            .navigationTitle("Clients")
            .navigationDestination(item: $selectedConnection) { connection in
                CoachClientDataView(connection: connection)
            }
            .task {
                await coachService.refreshCoachClientConnections()
            }
        }
    }
}

private struct CoachClientConnectionCard: View {
    let connection: CoachClientConnection

    private var displayName: String {
        let trimmed = connection.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Anonymous" : trimmed
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(CoachUIColor.accent.opacity(0.25))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(displayName.coachInitials)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Connected \(connection.connectedAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 10))
                    .foregroundStyle(CoachUIColor.muted)

                HStack(spacing: 6) {
                    permissionDot(color: connection.shareWorkouts ? CoachUIColor.accent : CoachUIColor.chipInactiveText, label: "Workouts")
                    permissionDot(color: connection.shareNutrition ? Color(red: 106 / 255, green: 171 / 255, blue: 238 / 255) : CoachUIColor.chipInactiveText, label: "Nutrition")
                    permissionDot(color: connection.shareProgress ? Color(red: 170 / 255, green: 120 / 255, blue: 220 / 255) : CoachUIColor.chipInactiveText, label: "Progress")
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Text("View data")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoachUIColor.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CoachUIColor.accent)
            }
        }
        .padding(.vertical, 4)
    }

    private func permissionDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(CoachUIColor.muted)
        }
    }
}

// MARK: - Messages

struct CoachMessagesTab: View {
    @EnvironmentObject private var coachService: CoachService
    @EnvironmentObject private var chatService: CoachChatService
    @State private var selectedConversation: ChatConversation?

    /// Auth-backed participant for unread dots + conversation listener.
    /// Never uses `portalProfile.id.uuidString` (placeholder wipe bug).
    private var coachParticipantId: String {
        if let uid = Auth.auth().currentUser?.uid,
           CoachChatService.isValidConversationParticipantId(uid) {
            return uid
        }
        let portal = coachService.portalProfile.coachUserID
        return CoachChatService.isValidConversationParticipantId(portal) ? portal : ""
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-bleed page color — empty VStack alone leaves NavigationStack's
                // default gray content column visible as a center strip.
                CoachUIColor.page.ignoresSafeArea()

                if chatService.conversations.isEmpty {
                    VStack {
                        Spacer()
                        Text("No messages yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(CoachUIColor.muted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(chatService.conversations) { conversation in
                        Button {
                            selectedConversation = conversation
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(conversation.userName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text(conversation.lastMessageAt.formatted(date: .omitted, time: .shortened))
                                            .font(.system(size: 9))
                                            .foregroundStyle(CoachUIColor.muted)
                                    }
                                    Text(conversation.lastMessage)
                                        .font(.system(size: 11))
                                        .foregroundStyle(CoachUIColor.muted)
                                        .lineLimit(1)
                                }

                                if !coachParticipantId.isEmpty,
                                   conversation.isUnread(for: coachParticipantId) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(CoachUIColor.card)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .toolbarBackground(CoachUIColor.page, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Messages")
            .navigationDestination(item: $selectedConversation) { conversation in
                CoachChatView(
                    conversationId: conversation.id,
                    coachId: conversation.coachId,
                    coachName: conversation.coachName,
                    coachSpecialty: "",
                    userId: conversation.userId,
                    userName: conversation.userName,
                    viewingAsCoach: true
                )
            }
            .onAppear {
                // Keep the shared unread listener alive across tabs — do not tear it down here.
                // Skip attach entirely when Auth uid / coachUserID is not ready yet (never UUID).
                let participant = coachParticipantId
                guard CoachChatService.isValidConversationParticipantId(participant) else {
                    print("[ChatSync] Messages tab skip observe — no Auth-backed participant yet")
                    return
                }
                chatService.observeConversations(forParticipant: participant)
            }
        }
    }
}

// MARK: - Preview

struct CoachPreviewTab: View {
    @EnvironmentObject private var coachService: CoachService
    @Binding var selectedTab: CoachPortalTab

    private var previewCoach: CoachProfile {
        coachService.portalProfile.asMarketplaceProfile()
    }

    var body: some View {
        CoachProfileScreen(
            coach: previewCoach,
            showsActionButtons: false,
            isPreviewMode: true,
            isProfileComplete: coachService.portalProfile.isComplete,
            onEditProfile: { selectedTab = .profile }
        )
    }
}
