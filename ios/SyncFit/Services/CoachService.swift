import Foundation
import CoreLocation
import SwiftData
import FirebaseAuth
import FirebaseFirestore

enum CoachActivationResult {
    case success
    case notSignedIn
    case invalidCode
    case revoked
    case unavailable
}

enum CoachProfileSaveState: Equatable {
    case idle
    case saving
    case saved
    case error
}

@MainActor
final class CoachService: NSObject, ObservableObject {
    private static let lastCoachModeKey = "lastCoachMode"

    @Published var marketplaceCoaches: [CoachProfile] = []
    @Published var isCoachModeActive = false
    @Published var isCoach = false
    @Published var profileSaveState: CoachProfileSaveState = .idle
    @Published var portalProfile = CoachPortalProfile()
    @Published var hiredCoachID: UUID?
    @Published var clientCoachConnection: CoachClientConnection?
    @Published var clientCoachConnections: [CoachClientConnection] = []
    @Published var activeFilter: CoachMarketplaceFilter = .all
    @Published var aiMatchFilterActive = false
    private var aiMatchGoal: FitnessGoal?
    private var aiMatchRoutineKind: WorkoutScheduleKind?
    @Published var conversations: [CoachConversation] = []
    @Published var messagesByConversation: [String: [CoachMessage]] = [:]
    @Published var clientConnections: [CoachClientConnection] = []
    @Published var routineTemplates: [CoachRoutineTemplate] = []
    @Published var userLocation: CLLocation?

    private let context: ModelContext
    private var firestore: FirestoreDatabaseManager?
    private var messageListeners: [String: ListenerRegistration] = [:]
    private let locationManager = CLLocationManager()

    init(context: ModelContext) {
        self.context = context
        super.init()
        loadSessionFromSettings()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func configure(firestore: FirestoreDatabaseManager) {
        self.firestore = firestore
        Task { await refreshMarketplaceCoaches() }
    }

    func seedFromLocalStore(_ coaches: [CoachProfile]) {
        if marketplaceCoaches.isEmpty {
            marketplaceCoaches = coaches.map { $0.sanitizedForDisplay() }
        }
    }

    #if DEBUG
    func seedDevCoachCodeIfNeeded() async {
        await firestore?.seedDevCoachCode()
    }
    #endif

    // MARK: - Marketplace filtering

    func filteredCoaches(
        searchText: String,
        coaches: [CoachProfile]
    ) -> [CoachProfile] {
        var results = coaches.filter(\.isListed)

        if aiMatchFilterActive, let aiMatchGoal {
            results = bestMatches(from: results, goal: aiMatchGoal, routineKind: aiMatchRoutineKind)
        } else {
            switch activeFilter {
            case .all:
                break
            case .muscleBuilding:
                results = results.filter { matchesSpecialty($0, keywords: ["muscle", "hypertrophy"]) }
            case .fatLoss:
                results = results.filter { matchesSpecialty($0, keywords: ["fat"]) }
            case .powerlifting:
                results = results.filter { matchesSpecialty($0, keywords: ["powerlifting"]) }
            case .strength:
                results = results.filter { matchesSpecialty($0, keywords: ["strength"]) }
            case .weightLoss:
                results = results.filter { matchesSpecialty($0, keywords: ["weight", "fat"]) }
            case .online:
                results = results.filter(\.availability.supportsOnline)
            case .nearMe:
                results = results.filter { coach in
                    coach.availability.supportsInPerson
                        && !coach.location.isEmpty
                        && isNearUser(coach.location)
                }
            }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return results }

        return results.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.specialty.localizedCaseInsensitiveContains(trimmed)
                || $0.specialties.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    func bestMatches(
        from coaches: [CoachProfile],
        goal: FitnessGoal,
        routineKind: WorkoutScheduleKind? = nil
    ) -> [CoachProfile] {
        var matchKeywords = keywordSet(for: goal)
        if let routineKind {
            matchKeywords.append(contentsOf: keywordSet(for: routineKind))
        }
        let ranked = coaches.sorted { lhs, rhs in
            matchScore(lhs, keywords: matchKeywords) > matchScore(rhs, keywords: matchKeywords)
        }
        return ranked
    }

    private func keywordSet(for goal: FitnessGoal) -> [String] {
        switch goal {
        case .buildMuscle: return ["muscle", "hypertrophy"]
        case .loseFat: return ["fat", "weight"]
        case .gainStrength: return ["strength", "powerlifting"]
        case .healthyLifestyle: return ["general", "strength"]
        }
    }

    private func keywordSet(for routineKind: WorkoutScheduleKind) -> [String] {
        switch routineKind {
        case .push, .pull, .legs, .upper, .lower, .arms, .backChest:
            return ["muscle", "hypertrophy", "bodybuilding"]
        case .fullBody:
            return ["strength", "general"]
        case .rest, .unassigned, .custom:
            return []
        }
    }

    func bestMatches(from coaches: [CoachProfile]) -> [CoachProfile] {
        coaches.sorted { $0.rating > $1.rating }
    }

    func requestNearMeFilter() {
        activeFilter = .nearMe
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    func applyAIMatch(goal: FitnessGoal, routineKind: WorkoutScheduleKind? = nil) {
        aiMatchFilterActive = true
        aiMatchGoal = goal
        aiMatchRoutineKind = routineKind
        activeFilter = .all
    }

    func clearAIMatch() {
        aiMatchFilterActive = false
        aiMatchGoal = nil
        aiMatchRoutineKind = nil
    }

    func coach(with id: UUID) -> CoachProfile? {
        marketplaceCoaches.first { $0.id == id }
    }

    func hiredCoach(from coaches: [CoachProfile]) -> CoachProfile? {
        guard let hiredCoachID else { return nil }
        return coaches.first { $0.id == hiredCoachID }
    }

    // MARK: - Coach auth & session

    func syncCoachStatusFromCloud(profileName: String) async {
        guard let firestore, let uid = Auth.auth().currentUser?.uid else { return }

        let hadLocalCoach = isCoach || settingsStoreIsCoach || isCoachModeActive
        let hasLocalPortal = !portalProfile.name.isEmpty
            || portalProfile.photoFileName != nil
            || !portalProfile.transformationPhotos.isEmpty
            || !loadSettings().coachPortalProfileJSON.isEmpty

        do {
            let status = try await firestore.fetchUserCoachStatus()

            if status.isCoach {
                isCoach = true
                settingsStoreIsCoach = true
                linkPortalProfileToCurrentUser(profileName: profileName)
                if Self.lastCoachModePreference {
                    enterCoachMode()
                }
            } else if hadLocalCoach && hasLocalPortal {
                #if DEBUG
                print("[CoachAuth] Restoring prior local coach session (cloud isCoach not set yet)")
                restoreLocalCoachAccess(profileName: profileName)
                await firestore.seedDevCoachCode()
                try? await firestore.activateCoachOnUser(activatedAt: Date())
                if Self.lastCoachModePreference {
                    enterCoachMode()
                }
                #else
                isCoach = false
                settingsStoreIsCoach = false
                if isCoachModeActive { exitCoachMode() }
                #endif
            } else {
                isCoach = false
                settingsStoreIsCoach = false
                persistLastCoachMode(false)
                if isCoachModeActive { exitCoachMode() }
            }

            #if DEBUG
            await firestore.seedDevCoachCode()
            #endif
        } catch {
            #if DEBUG
            if hadLocalCoach && hasLocalPortal {
                print("[CoachAuth] Cloud sync failed — keeping local coach session")
                restoreLocalCoachAccess(profileName: profileName)
                await firestore.seedDevCoachCode()
                if Self.lastCoachModePreference {
                    enterCoachMode()
                }
            }
            #endif
        }
    }

    func activateCoachCode(_ plainCode: String, profileName: String) async -> CoachActivationResult {
        guard Auth.auth().currentUser != nil else {
            return .notSignedIn
        }

        #if DEBUG
        if CoachDevSeed.isDevCoachCode(plainCode) {
            print("[CoachAuth] DEBUG dev code accepted — entering coach mode")
            await firestore?.seedDevCoachCode()
            grantCoachAccess(profileName: profileName)
            if let firestore {
                try? await firestore.activateCoachOnUser(activatedAt: Date())
                try? await firestore.activateCoachAccessCode(plainCode)
            }
            return .success
        }
        #endif

        guard let firestore else {
            return .unavailable
        }

        do {
            try await firestore.activateCoachAccessCode(plainCode)
            grantCoachAccess(profileName: profileName)
            return .success
        } catch let error as CoachCodeActivationError {
            switch error {
            case .notAuthenticated:
                return .notSignedIn
            case .revoked:
                return .revoked
            case .notFound, .userMismatch:
                return .invalidCode
            }
        } catch {
            return .unavailable
        }
    }

    func grantCoachAccess(profileName: String) {
        isCoach = true
        settingsStoreIsCoach = true
        linkPortalProfileToCurrentUser(profileName: profileName)
        enterCoachMode()
    }

    private func restoreLocalCoachAccess(profileName: String) {
        isCoach = true
        settingsStoreIsCoach = true
        linkPortalProfileToCurrentUser(profileName: profileName)
    }

    func enterCoachMode() {
        guard isCoach else { return }
        isCoachModeActive = true
        persistLastCoachMode(true)
        persistSession()
        Task { await syncPortalProfileToCloud() }
    }

    func exitCoachMode() {
        isCoachModeActive = false
        persistLastCoachMode(false)
        persistSession()
        stopAllMessageListeners()
    }

    func setCoachModeActive(_ active: Bool) {
        if active {
            enterCoachMode()
        } else {
            exitCoachMode()
        }
    }

    func clearCoachSessionOnSignOut() {
        resetForUserSwitch()
    }

    func resetForUserSwitch() {
        isCoach = false
        isCoachModeActive = false
        settingsStoreIsCoach = false
        persistLastCoachMode(false)
        stopAllMessageListeners()
        messagesByConversation = [:]
        conversations = []
        clientConnections = []
        clientCoachConnections = []
        clientCoachConnection = nil
        hiredCoachID = nil
        routineTemplates = []
        portalProfile = CoachPortalProfile()
        persistSession()
    }

    func savePortalProfile() {
        portalProfile.isLive = portalProfile.isComplete
        persistSession()
        if let index = marketplaceCoaches.firstIndex(where: { $0.id == portalProfile.id }) {
            marketplaceCoaches[index] = portalProfile.asMarketplaceProfile()
        }
        Task { await syncPortalProfileToCloud() }
    }

    @discardableResult
    func savePortalProfileAsync() async -> Bool {
        do {
            try await savePortalProfileToCloud()
            return true
        } catch {
            print("Save error: \(error)")
            return false
        }
    }

    func savePortalProfileToCloud() async throws {
        persistPortalProfileLocally()
        try await uploadPortalProfileToCloud()
    }

    func persistPortalProfileLocally() {
        if let uid = Auth.auth().currentUser?.uid, portalProfile.coachUserID.isEmpty {
            portalProfile.coachUserID = uid
        }

        portalProfile.isLive = portalProfile.isComplete
        persistSession()
        if let index = marketplaceCoaches.firstIndex(where: { $0.id == portalProfile.id }) {
            marketplaceCoaches[index] = portalProfile.asMarketplaceProfile()
        }
    }

    func uploadPortalProfileToCloud() async throws {
        guard let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        guard isCoach else {
            throw FirestoreDatabaseError.notAuthenticated
        }
        guard Auth.auth().currentUser?.uid != nil else {
            throw FirestoreDatabaseError.notAuthenticated
        }

        let profile = portalProfile.asMarketplaceProfile()
        print("[CoachSave] Writing coaches/\(profile.coachFirestoreID)")
        try await firestore.saveCoachProfile(profile)
        print("[CoachSave] Firestore write completed")
    }

    func performProfileSave() async {
        guard profileSaveState != .saving else { return }

        profileSaveState = .saving
        print("[CoachSave] started")

        persistPortalProfileLocally()

        do {
            try await uploadPortalProfileToCloud()
            profileSaveState = .saved
            print("[CoachSave] local + cloud save complete")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if profileSaveState == .saved {
                profileSaveState = .idle
            }
        } catch {
            print("[CoachSave] cloud error: \(error)")
            profileSaveState = .error
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if profileSaveState == .error {
                profileSaveState = .idle
            }
        }
    }

    /// Pulls text fields from `coaches/{uid}` into the portal when local editor is empty
    /// or after an account switch. Photos remain device-local until Storage is wired.
    func hydratePortalProfileFromCloudIfNeeded() async {
        guard let firestore, isCoach else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }

        do {
            guard let cloud = try await firestore.fetchCoachProfile(coachFirestoreID: uid) else {
                return
            }

            let localEmpty = portalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && portalProfile.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && portalProfile.specialties.isEmpty

            // Always refresh listing/live flags from cloud; fill text when local is empty
            // or when cloud has a richer name/about for this UID.
            if localEmpty || cloud.name != portalProfile.name || cloud.bio != portalProfile.about {
                portalProfile.coachUserID = uid
                if portalProfile.id == UUID() || localEmpty {
                    portalProfile.id = cloud.id
                }
                if localEmpty || portalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    portalProfile.name = cloud.name
                }
                if localEmpty || portalProfile.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    portalProfile.about = cloud.bio
                }
                if localEmpty || portalProfile.specialties.isEmpty {
                    portalProfile.specialties = cloud.specialties
                }
                if localEmpty {
                    portalProfile.ratePerMonth = cloud.pricePerMonth
                    portalProfile.availability = cloud.availability
                    portalProfile.location = cloud.location
                }
            }

            portalProfile.isLive = cloud.isLive
            portalProfile.isListed = cloud.isListed
            portalProfile.coachUserID = uid
            persistSession()
            print("[CoachAuth] Hydrated portal from coaches/\(uid)")
        } catch {
            print("[CoachAuth] Portal hydrate failed: \(error)")
        }
    }

    func setHiredCoach(_ coach: CoachProfile?) {
        hiredCoachID = coach?.id
        persistSession()
    }

    func hireCoach(
        _ coach: CoachProfile,
        clientName: String,
        shareWorkouts: Bool,
        shareNutrition: Bool,
        shareProgress: Bool
    ) async throws {
        // TODO: Replace this direct connection with Stripe payment flow
        // When Stripe is integrated:
        // 1. Create Stripe Checkout session server-side
        // 2. Open payment URL in Safari
        // 3. On successful payment webhook → create coach_clients document
        // 4. Deep link back to app and show success state
        // For now: create connection directly without payment
        try await createConnection(
            coach: coach,
            clientName: clientName,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress
        )
    }

    func createConnection(
        coach: CoachProfile,
        clientName: String,
        shareWorkouts: Bool,
        shareNutrition: Bool,
        shareProgress: Bool
    ) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreDatabaseError.notAuthenticated
        }
        guard let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }

        let connection = makeConnection(
            coach: coach,
            clientUserID: uid,
            clientName: clientName,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress
        )

        try await firestore.saveCoachClientConnection(connection)
        clientCoachConnection = connection
        upsertClientConnection(connection)
        setHiredCoach(coach)
        await refreshCoachClientConnections()
    }

    /// Updates local state immediately, then persists to Firestore in the background.
    func connectOptimistically(
        coach: CoachProfile,
        clientName: String,
        shareWorkouts: Bool,
        shareNutrition: Bool,
        shareProgress: Bool
    ) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let connection = makeConnection(
            coach: coach,
            clientUserID: uid,
            clientName: clientName,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress
        )

        clientCoachConnection = connection
        upsertClientConnection(connection)
        setHiredCoach(coach)

        Task {
            guard let firestore else { return }
            try? await firestore.saveCoachClientConnection(connection)
            await refreshClientCoachConnection()
        }
    }

    var connectedCoachFirestoreIDs: Set<String> {
        Set(clientCoachConnections.filter(\.isActive).map(\.coachFirestoreID))
    }

    func coachProfile(
        for connection: CoachClientConnection,
        localCoaches: [CoachProfile]
    ) -> CoachProfile? {
        coach(with: connection.coachID)
            ?? marketplaceCoaches.first(where: { $0.coachFirestoreID == connection.coachFirestoreID })
            ?? localCoaches.first(where: { $0.coachFirestoreID == connection.coachFirestoreID })
    }

    private func upsertClientConnection(_ connection: CoachClientConnection) {
        if let index = clientCoachConnections.firstIndex(where: { $0.documentID == connection.documentID }) {
            clientCoachConnections[index] = connection
        } else {
            clientCoachConnections.append(connection)
        }
    }

    private func removeClientConnection(_ connection: CoachClientConnection) {
        clientCoachConnections.removeAll { $0.documentID == connection.documentID }
    }

    func upsertClientConnectionForUI(_ connection: CoachClientConnection) {
        upsertClientConnection(connection)
    }

    func isConnectedTo(coachFirestoreID: String) -> Bool {
        clientCoachConnections.contains { $0.isActive && $0.coachFirestoreID == coachFirestoreID }
    }

    func connection(with coachFirestoreID: String) -> CoachClientConnection? {
        clientCoachConnections.first { $0.isActive && $0.coachFirestoreID == coachFirestoreID }
    }

    private func makeConnection(
        coach: CoachProfile,
        clientUserID: String,
        clientName: String,
        shareWorkouts: Bool,
        shareNutrition: Bool,
        shareProgress: Bool
    ) -> CoachClientConnection {
        CoachClientConnection(
            coachID: coach.id,
            coachFirestoreID: coach.coachFirestoreID,
            coachName: coach.name,
            clientUserID: clientUserID,
            clientName: clientName,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress,
            status: .active,
            clientInitiatedContact: true
        )
    }

    func fetchConnection(with coachFirestoreID: String) async -> CoachClientConnection? {
        guard let uid = Auth.auth().currentUser?.uid, let firestore else { return nil }
        return try? await firestore.fetchClientCoachConnection(
            clientUserID: uid,
            coachFirestoreID: coachFirestoreID
        )
    }

    func disconnectFromCoach() async throws {
        guard var connection = clientCoachConnection, let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        connection.status = .inactive
        try await firestore.saveCoachClientConnection(connection)
        removeClientConnection(connection)
        if clientCoachConnection?.documentID == connection.documentID {
            clientCoachConnection = clientCoachConnections.first
        }
        if clientCoachConnections.isEmpty {
            setHiredCoach(nil)
        }
    }

    func disconnectFromCoach(_ connection: CoachClientConnection) async throws {
        guard var mutable = clientCoachConnections.first(where: { $0.documentID == connection.documentID }),
              let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        mutable.status = .inactive
        try await firestore.saveCoachClientConnection(mutable)
        removeClientConnection(mutable)
        if clientCoachConnection?.documentID == mutable.documentID {
            clientCoachConnection = clientCoachConnections.first
        }
        if clientCoachConnections.isEmpty {
            setHiredCoach(nil)
        }
    }

    func refreshCoachClientConnections() async {
        guard let firestore else { return }
        let coachKey = coachFirestoreID
        do {
            clientConnections = try await firestore.fetchCoachClientConnections(coachFirestoreID: coachKey)
        } catch {
            // Keep cached list.
        }
    }

    var coachFirestoreID: String {
        if let uid = Auth.auth().currentUser?.uid {
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if !portalProfile.coachUserID.isEmpty {
            return portalProfile.coachUserID
        }
        return portalProfile.id.uuidString
    }

    func refreshRoutineTemplates() async {
        guard let firestore else {
            routineTemplates = loadRoutineTemplatesFromDisk()
            return
        }
        do {
            routineTemplates = try await firestore.fetchCoachRoutineTemplates(coachFirestoreID: coachFirestoreID)
            persistRoutineTemplatesToDisk(routineTemplates)
        } catch {
            print("[CoachRoutines] refresh failed: \(error)")
            if routineTemplates.isEmpty {
                routineTemplates = loadRoutineTemplatesFromDisk()
            }
        }
    }

    func saveRoutineTemplate(_ template: CoachRoutineTemplate) async throws {
        guard let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        var updated = template
        updated.updatedAt = .now
        upsertRoutineTemplateLocally(updated)
        persistRoutineTemplatesToDisk(routineTemplates)
        try await firestore.saveCoachRoutineTemplate(updated, coachFirestoreID: coachFirestoreID)
        await refreshRoutineTemplates()
    }

    func deleteRoutineTemplate(_ template: CoachRoutineTemplate) async throws {
        guard let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        try await firestore.deleteCoachRoutineTemplate(template, coachFirestoreID: coachFirestoreID)
        routineTemplates.removeAll { $0.id == template.id }
        persistRoutineTemplatesToDisk(routineTemplates)
    }

    private func upsertRoutineTemplateLocally(_ template: CoachRoutineTemplate) {
        if let index = routineTemplates.firstIndex(where: { $0.id == template.id }) {
            routineTemplates[index] = template
        } else {
            routineTemplates.insert(template, at: 0)
        }
    }

    private func routineTemplatesStorageKey() -> String {
        "coachRoutineTemplates.\(coachFirestoreID)"
    }

    private func loadRoutineTemplatesFromDisk() -> [CoachRoutineTemplate] {
        guard let data = UserDefaults.standard.data(forKey: routineTemplatesStorageKey()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CoachRoutineTemplate].self, from: data)) ?? []
    }

    private func persistRoutineTemplatesToDisk(_ templates: [CoachRoutineTemplate]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: routineTemplatesStorageKey())
    }

    func refreshClientCoachConnection() async {
        guard let uid = Auth.auth().currentUser?.uid, let firestore else { return }
        do {
            clientCoachConnections = try await firestore.fetchActiveClientConnections(clientUserID: uid)
            clientCoachConnection = clientCoachConnections.first
            if let connection = clientCoachConnection,
               let coach = marketplaceCoaches.first(where: { $0.coachFirestoreID == connection.coachFirestoreID }) {
                setHiredCoach(coach)
            } else if clientCoachConnections.isEmpty {
                setHiredCoach(nil)
            }
        } catch {
            // Keep local hire state.
        }
    }

    func updateClientCoachPermissions(
        for connection: CoachClientConnection,
        shareWorkouts: Bool,
        shareNutrition: Bool,
        shareProgress: Bool
    ) async throws {
        guard let firestore else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        var updated = connection
        updated.shareWorkouts = shareWorkouts
        updated.shareNutrition = shareNutrition
        updated.shareProgress = shareProgress
        try await firestore.saveCoachClientConnection(updated)
        upsertClientConnection(updated)
        if clientCoachConnection?.documentID == updated.documentID {
            clientCoachConnection = updated
        }
    }

    func updateClientCoachPermissions(
        shareWorkouts: Bool,
        shareNutrition: Bool,
        shareProgress: Bool
    ) async throws {
        guard let connection = clientCoachConnection else {
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        try await updateClientCoachPermissions(
            for: connection,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress
        )
    }

    // MARK: - Messaging

    func sendMessage(conversationID: String, text: String, asCoach: Bool, clientUserID: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = CoachMessage(
            conversationID: conversationID,
            senderRole: asCoach ? .coach : .client,
            text: trimmed
        )
        messagesByConversation[conversationID, default: []].append(message)

        guard let firestore else { return }
        do {
            try await firestore.saveCoachMessage(
                message,
                coachFirestoreID: portalProfile.coachUserID.isEmpty
                    ? portalProfile.id.uuidString
                    : portalProfile.coachUserID,
                clientUserID: clientUserID
            )
        } catch {
            // Local optimistic update remains.
        }
    }

    func observeConversation(_ conversationID: String, coachFirestoreID: String) {
        guard messageListeners[conversationID] == nil, let firestore else { return }
        messageListeners[conversationID] = firestore.observeCoachMessages(
            conversationID: conversationID,
            coachFirestoreID: coachFirestoreID
        ) { [weak self] messages in
            Task { @MainActor in
                self?.messagesByConversation[conversationID] = messages
                self?.refreshConversations()
            }
        }
    }

    func stopAllMessageListeners() {
        messageListeners.values.forEach { $0.remove() }
        messageListeners.removeAll()
    }

    // MARK: - Private

    private var settingsStoreIsCoach: Bool {
        get { loadSettings().userIsCoach }
        set {
            let settings = loadSettings()
            settings.userIsCoach = newValue
            try? context.save()
        }
    }

    private func linkPortalProfileToCurrentUser(profileName: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let hasExistingPortal = !portalProfile.name.isEmpty
            || portalProfile.photoFileName != nil
            || !portalProfile.transformationPhotos.isEmpty

        portalProfile.coachUserID = uid
        if !hasExistingPortal {
            portalProfile.id = CoachAuthCrypto.stableCoachUUID(from: uid)
        }

        if portalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            portalProfile.name = profileName
        }
        persistSession()
    }

    private func refreshConversations() {
        conversations = messagesByConversation.map { key, messages in
            let sorted = messages.sorted { $0.sentAt > $1.sentAt }
            let last = sorted.first
            return CoachConversation(
                id: key,
                clientName: conversationDisplayName(for: key),
                lastMessage: last?.text ?? "",
                lastMessageAt: last?.sentAt ?? .distantPast
            )
        }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    private func conversationDisplayName(for conversationID: String) -> String {
        clientConnections.first { $0.documentID == conversationID }?.clientName ?? "Client"
    }

    private func matchScore(_ coach: CoachProfile, keywords: [String]) -> Int {
        let haystack = ([coach.specialty] + coach.specialties + [coach.bio])
            .joined(separator: " ")
            .lowercased()
        return keywords.reduce(0) { score, keyword in
            haystack.contains(keyword) ? score + 1 : score
        }
    }

    private func matchesSpecialty(_ coach: CoachProfile, keywords: [String]) -> Bool {
        matchScore(coach, keywords: keywords) > 0
    }

    private func isNearUser(_ coachLocation: String) -> Bool {
        guard let userLocation else { return coachLocation.localizedCaseInsensitiveContains("austin") }
        return coachLocation.localizedCaseInsensitiveContains("austin")
            || userLocation.coordinate.latitude > 29 && userLocation.coordinate.latitude < 31
    }

    private func loadSessionFromSettings() {
        let settings = loadSettings()
        isCoach = settings.userIsCoach
        hiredCoachID = UUID(uuidString: settings.hiredCoachID)
        if let data = settings.coachPortalProfileJSON.data(using: .utf8),
           var profile = try? JSONDecoder().decode(CoachPortalProfile.self, from: data) {
            if profile.sanitizePlaceholderContent() {
                portalProfile = profile
                persistSession()
                Task { await syncPortalProfileToCloud() }
            } else {
                portalProfile = profile
            }
        } else if !settings.coachSessionID.isEmpty, let id = UUID(uuidString: settings.coachSessionID) {
            portalProfile.id = id
        }

        if isCoach && Self.lastCoachModePreference {
            isCoachModeActive = true
        } else {
            isCoachModeActive = settings.coachModeActive
        }
    }

    private func persistSession() {
        let settings = loadSettings()
        settings.coachModeActive = isCoachModeActive
        settings.userIsCoach = isCoach
        settings.coachSessionID = portalProfile.id.uuidString
        settings.hiredCoachID = hiredCoachID?.uuidString ?? ""
        if let data = try? JSONEncoder().encode(portalProfile),
           let json = String(data: data, encoding: .utf8) {
            settings.coachPortalProfileJSON = json
        }
        try? context.save()
    }

    private static var lastCoachModePreference: Bool {
        UserDefaults.standard.bool(forKey: lastCoachModeKey)
    }

    private func persistLastCoachMode(_ active: Bool) {
        UserDefaults.standard.set(active, forKey: Self.lastCoachModeKey)
    }

    private func loadSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        context.insert(settings)
        return settings
    }

    private func refreshMarketplaceCoaches() async {
        guard let firestore else { return }
        do {
            let remote = try await firestore.fetchCoachProfiles().map { $0.sanitizedForDisplay() }
            if !remote.isEmpty {
                let localIDs = Set(marketplaceCoaches.map(\.id))
                let merged = marketplaceCoaches + remote.filter { !localIDs.contains($0.id) && $0.isLive && $0.isListed }
                marketplaceCoaches = merged.map { $0.sanitizedForDisplay() }
            }
            let coachKey = portalProfile.coachUserID.isEmpty
                ? portalProfile.id.uuidString
                : portalProfile.coachUserID
            clientConnections = try await firestore.fetchCoachClientConnections(coachFirestoreID: coachKey)
        } catch {
            // Local mock coaches remain available.
        }
    }

    @discardableResult
    private func syncPortalProfileToCloud() async -> Bool {
        do {
            try await savePortalProfileToCloud()
            return true
        } catch {
            print("Save error: \(error)")
            return false
        }
    }
}

extension CoachService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            userLocation = location
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
