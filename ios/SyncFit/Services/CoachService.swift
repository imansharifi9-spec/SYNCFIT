import Foundation
import CoreLocation
import SwiftData
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import AuthenticationServices
import UIKit

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

enum CoachHireCheckoutState: Equatable {
    case idle
    case creatingCheckout
    case authenticating
    case confirming
    case confirmationTimedOut
    case confirmed
    case canceled
    case failed(String)
}

struct CoachStripeStatus: Equatable {
    var chargesEnabled: Bool
    var hasConnectedAccount: Bool

    static let unknown = CoachStripeStatus(chargesEnabled: false, hasConnectedAccount: false)
}

enum CoachStripeOnboardingState: Equatable, CustomStringConvertible {
    case idle
    case creatingLink
    case authenticating
    case waitingForWebhook
    case complete
    case canceled
    case failed(String)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .creatingLink: return "creatingLink"
        case .authenticating: return "authenticating"
        case .waitingForWebhook: return "waitingForWebhook"
        case .complete: return "complete"
        case .canceled: return "canceled"
        case .failed(let message): return "failed(\(message))"
        }
    }
}

enum CoachStripeOnboardingCallbackResult: Equatable {
    case returned
    case refresh
    case invalid
}

/// Validates `syncfit://stripe-onboarding-return` (+ optional `refresh=1`) from Account Links.
enum CoachStripeOnboardingCallbackValidator {
    static func result(for url: URL) -> CoachStripeOnboardingCallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "syncfit",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.host == "stripe-onboarding-return" else {
            return .invalid
        }

        let items = components.queryItems ?? []
        if items.isEmpty {
            return .returned
        }
        guard items.count == 1,
              items[0].name == "refresh",
              items[0].value == "1" else {
            return .invalid
        }
        return .refresh
    }
}

enum CoachCheckoutConfirmationCopy {
    static let confirmingTitle = "Confirming your subscription..."
    static let timeoutMessage =
        "Still confirming — this can take a moment. Check back shortly."
    static let refreshTitle = "Refresh"
    static let canceledMessage = "Checkout was canceled"
}

enum CoachCheckoutConfirmationTiming {
    static let standardTimeoutNanoseconds: UInt64 = 15_000_000_000

    #if DEBUG
    /// DEBUG only: when true, confirmation timeout fires immediately so the
    /// fallback UI can be verified without waiting 15 seconds.
    static var forceImmediateTimeout = false
    #endif

    static var timeoutNanoseconds: UInt64 {
        #if DEBUG
        forceImmediateTimeout ? 0 : standardTimeoutNanoseconds
        #else
        standardTimeoutNanoseconds
        #endif
    }
}

enum CoachCheckoutCallbackResult: Equatable {
    case success
    case canceled
    case invalid
}

enum CoachCheckoutCallbackValidator {
    static func result(for url: URL) -> CoachCheckoutCallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "syncfit",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return .invalid
        }

        if components.host == "coach-checkout-cancel" {
            return components.percentEncodedQuery == nil ? .canceled : .invalid
        }

        guard components.host == "coach-checkout-success",
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "session_id",
              let sessionID = queryItems[0].value,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid
        }
        return .success
    }
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
    @Published private(set) var hireCheckoutState: CoachHireCheckoutState = .idle
    @Published private(set) var hireCheckoutCoachUID: String?
    @Published private(set) var liveStripeChargesEnabled: [String: Bool] = [:]
    @Published private(set) var ownStripeStatus: CoachStripeStatus = .unknown
    @Published private(set) var stripeOnboardingState: CoachStripeOnboardingState = .idle

    private let context: ModelContext
    private var firestore: FirestoreDatabaseManager?
    private var messageListeners: [String: ListenerRegistration] = [:]
    private var stripeAvailabilityListeners: [String: ListenerRegistration] = [:]
    private var ownStripeStatusListener: ListenerRegistration?
    private var coachConnectionListener: ListenerRegistration?
    private var checkoutConfirmationTimeoutTask: Task<Void, Never>?
    private var checkoutSession: ASWebAuthenticationSession?
    private var stripeOnboardingSession: ASWebAuthenticationSession?
    /// Bumped whenever a new onboarding attempt starts so stale ASWebAuth callbacks are ignored.
    private var stripeOnboardingGeneration = 0
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
        startObservingOwnStripeStatus()
        Task { await syncPortalProfileToCloud() }
    }

    func exitCoachMode() {
        isCoachModeActive = false
        persistLastCoachMode(false)
        persistSession()
        stopAllMessageListeners()
        stopObservingOwnStripeStatus()
        stripeOnboardingSession?.cancel()
        stripeOnboardingSession = nil
        if case .complete = stripeOnboardingState {
            // Keep complete until next observe refresh.
        } else {
            stripeOnboardingState = .idle
        }
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
        checkoutSession?.cancel()
        checkoutSession = nil
        cancelCheckoutConfirmation()
        stripeAvailabilityListeners.values.forEach { $0.remove() }
        stripeAvailabilityListeners.removeAll()
        liveStripeChargesEnabled.removeAll()
        stopObservingOwnStripeStatus()
        ownStripeStatus = .unknown
        stripeOnboardingSession?.cancel()
        stripeOnboardingSession = nil
        stripeOnboardingState = .idle
        hireCheckoutCoachUID = nil
        hireCheckoutState = .idle
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
            print("[CoachSave] FAILED — Firestore unavailable")
            throw FirestoreDatabaseError.firebaseUnavailable
        }
        guard isCoach else {
            print("[CoachSave] FAILED — user is not a coach")
            throw FirestoreDatabaseError.notAuthenticated
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            print("[CoachSave] FAILED — not authenticated")
            throw FirestoreDatabaseError.notAuthenticated
        }

        // Keep portal + marketplace payload on the Auth UID so rules + marketplace agree.
        portalProfile.coachUserID = uid
        if !portalProfile.isComplete {
            print("[CoachSave] WARNING — profile incomplete; isLive will be false (marketplace hides it). nameEmpty=\(portalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) specialtiesEmpty=\(portalProfile.specialties.isEmpty) aboutEmpty=\(portalProfile.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
        }

        let profile = portalProfile.asMarketplaceProfile()
        print("[CoachSave] PART1 local portal ready uid=\(uid) portalID=\(portalProfile.id.uuidString) complete=\(portalProfile.isComplete) listed=\(portalProfile.isListed) live=\(profile.isLive)")
        try await firestore.saveCoachProfile(profile)
        // Refresh marketplace so this device immediately sees the live listing.
        await refreshMarketplaceCoaches()
        print("[CoachSave] PART2 cloud + marketplace refresh done")
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
    /// or after an account switch. Also restores photoURL when present in cloud.
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

            if let photoURL = cloud.photoURL, !photoURL.isEmpty {
                portalProfile.photoURL = photoURL
            }
            if let photoFileName = cloud.photoFileName, !photoFileName.isEmpty {
                portalProfile.photoFileName = photoFileName
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

    func observeStripeAvailability(for coach: CoachProfile) {
        let coachUID = coach.coachFirestoreID
        guard stripeAvailabilityListeners[coachUID] == nil, let firestore else { return }
        liveStripeChargesEnabled[coachUID] = false
        stripeAvailabilityListeners[coachUID] = firestore.observeCoachStripeChargesEnabled(
            coachFirestoreID: coachUID,
            onChange: { [weak self] enabled in
                Task { @MainActor in
                    self?.liveStripeChargesEnabled[coachUID] = enabled
                }
            },
            onError: { [weak self] _ in
                Task { @MainActor in
                    self?.liveStripeChargesEnabled[coachUID] = false
                }
            }
        )
    }

    func stopObservingStripeAvailability(coachUID: String) {
        stripeAvailabilityListeners.removeValue(forKey: coachUID)?.remove()
        liveStripeChargesEnabled.removeValue(forKey: coachUID)
    }

    /// Observe the signed-in coach's own `coaches/{uid}` Stripe fields while in coach mode.
    func startObservingOwnStripeStatus() {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty, let firestore else {
            Self.logStripeConnect(
                "startObservingOwnStripeStatus skipped — uid=\(Auth.auth().currentUser?.uid ?? "nil") firestore=\(firestore != nil)"
            )
            return
        }
        // Always pull a server snapshot so a previously-attached listener (or a
        // cached false) cannot leave the Payments UI stuck after webhook write.
        Task { await self.refreshOwnStripeStatusFromServer() }

        if ownStripeStatusListener != nil {
            Self.logStripeConnect(
                "startObservingOwnStripeStatus listener already attached uid=\(uid) current=\(ownStripeStatus)"
            )
            return
        }
        Self.logStripeConnect("Attaching coaches/\(uid) stripe snapshot listener")
        ownStripeStatusListener = firestore.observeCoachStripeStatus(
            coachFirestoreID: uid,
            onChange: { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    Self.logStripeConnect(
                        "listener snapshot uid=\(uid) chargesEnabled=\(status.chargesEnabled) hasConnectedAccount=\(status.hasConnectedAccount) onboarding=\(self.stripeOnboardingState)"
                    )
                    self.applyOwnStripeStatus(status, uid: uid, source: "listener")
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    Self.logStripeConnect("listener ERROR uid=\(uid): \(error.localizedDescription)")
                    self?.ownStripeStatus = .unknown
                }
            }
        )
    }

    /// Server-authoritative refresh of `coaches/{uid}` Stripe flags (bypasses local cache).
    func refreshOwnStripeStatusFromServer() async {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty, let firestore else {
            Self.logStripeConnect("refreshOwnStripeStatusFromServer skipped — no auth/firestore")
            return
        }
        do {
            let status = try await firestore.fetchCoachStripeStatus(coachFirestoreID: uid)
            Self.logStripeConnect(
                "server refresh uid=\(uid) chargesEnabled=\(status.chargesEnabled) hasConnectedAccount=\(status.hasConnectedAccount) onboarding=\(stripeOnboardingState)"
            )
            applyOwnStripeStatus(status, uid: uid, source: "server")
        } catch {
            Self.logStripeConnect("server refresh ERROR uid=\(uid): \(error.localizedDescription)")
        }
    }

    private func applyOwnStripeStatus(_ status: CoachStripeStatus, uid: String, source: String) {
        ownStripeStatus = status
        liveStripeChargesEnabled[uid] = status.chargesEnabled
        if status.chargesEnabled {
            stripeOnboardingState = .complete
        } else if stripeOnboardingState == .complete {
            stripeOnboardingState = .idle
        }
        Self.logStripeConnect(
            "apply[\(source)] chargesEnabled=\(status.chargesEnabled) hasConnectedAccount=\(status.hasConnectedAccount) → onboarding=\(stripeOnboardingState)"
        )
    }

    func stopObservingOwnStripeStatus() {
        ownStripeStatusListener?.remove()
        ownStripeStatusListener = nil
    }

    /// Xcode console + /tmp probe file so Simulator verification can see the fixed build.
    private static func logStripeConnect(_ message: String) {
        let line = "[StripeConnect] \(message)"
        print(line)
        NSLog("%@", line)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let payload = "\(stamp) \(line)\n"
        let url = URL(fileURLWithPath: "/tmp/syncfit-stripeconnect-probe.log")
        if let data = payload.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Create/reuse Stripe Express Account Link and open it in ASWebAuthenticationSession.
    /// A new tap always mints a fresh Account Link except while the callable itself is in flight.
    /// Stuck `.authenticating` / `.waitingForWebhook` sessions are superseded so the coach
    /// never gets stuck reusing an expired browser session.
    func beginStripeConnectOnboarding() async {
        if stripeOnboardingState == .creatingLink {
            Self.logStripeConnect("createCoachStripeAccount was already running — ignoring duplicate tap")
            return
        }
        guard Auth.auth().currentUser != nil else {
            stripeOnboardingState = .failed("Sign in as a coach to set up payments.")
            return
        }
        // Re-check server before minting a link — webhook may have already flipped the flag.
        await refreshOwnStripeStatusFromServer()
        if ownStripeStatus.chargesEnabled {
            Self.logStripeConnect("beginStripeConnectOnboarding short-circuit — chargesEnabled already true")
            stripeOnboardingState = .complete
            return
        }

        // Supersede any open/waiting session so the next callable returns a brand-new Account Link.
        stripeOnboardingGeneration += 1
        let generation = stripeOnboardingGeneration
        if stripeOnboardingSession != nil
            || stripeOnboardingState == .authenticating
            || stripeOnboardingState == .waitingForWebhook
        {
            let previous = stripeOnboardingSession
            stripeOnboardingSession = nil
            previous?.cancel()
            Self.logStripeConnect("Superseded prior onboarding session (generation \(generation))")
        }

        startObservingOwnStripeStatus()
        stripeOnboardingState = .creatingLink
        Self.logStripeConnect("Minting Account Link (generation \(generation))")

        do {
            let result = try await Functions.functions()
                .httpsCallable("createCoachStripeAccount")
                .call([:] as [String: Any])
            guard generation == stripeOnboardingGeneration else { return }
            guard let response = result.data as? [String: Any],
                  let rawURL = response["url"] as? String,
                  let onboardingURL = URL(string: rawURL) else {
                stripeOnboardingState = .failed("Couldn't open Stripe setup. Please try again.")
                return
            }
            // Account id is now on the coach doc (or reused) — observer will pick up hasConnectedAccount.
            openStripeOnboarding(onboardingURL, generation: generation)
        } catch {
            guard generation == stripeOnboardingGeneration else { return }
            stripeOnboardingState = .failed(error.localizedDescription)
        }
    }

    private func openStripeOnboarding(_ url: URL, generation: Int) {
        stripeOnboardingSession?.cancel()
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "syncfit"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                // Ignore cancel/complete from a session the coach already replaced with a new tap.
                guard generation == self.stripeOnboardingGeneration else { return }
                self.stripeOnboardingSession = nil

                if let authenticationError = error as? ASWebAuthenticationSessionError,
                   authenticationError.code == .canceledLogin {
                    self.stripeOnboardingState = .canceled
                    return
                }
                if let error {
                    self.stripeOnboardingState = .failed(error.localizedDescription)
                    return
                }
                guard let callbackURL else {
                    self.stripeOnboardingState = .failed("Stripe setup returned no callback.")
                    return
                }
                switch CoachStripeOnboardingCallbackValidator.result(for: callbackURL) {
                case .invalid:
                    self.stripeOnboardingState = .failed("Stripe setup returned an invalid callback.")
                case .returned, .refresh:
                    // Never assume success — wait for stripeChargesEnabled via Firestore.
                    if self.ownStripeStatus.chargesEnabled {
                        self.stripeOnboardingState = .complete
                    } else {
                        self.stripeOnboardingState = .waitingForWebhook
                        self.startObservingOwnStripeStatus()
                    }
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        stripeOnboardingSession = session
        stripeOnboardingState = .authenticating
        if !session.start() {
            stripeOnboardingSession = nil
            stripeOnboardingState = .failed("Couldn't open Stripe setup. Please try again.")
        }
    }

    func beginCoachCheckout(for coach: CoachProfile) async {
        let coachUID = coach.coachFirestoreID
        guard hireCheckoutState != .creatingCheckout,
              hireCheckoutState != .authenticating,
              hireCheckoutState != .confirming else { return }
        guard Auth.auth().currentUser != nil else {
            hireCheckoutCoachUID = coachUID
            hireCheckoutState = .failed("Sign in to hire this coach.")
            return
        }
        guard let firestore else {
            hireCheckoutCoachUID = coachUID
            hireCheckoutState = .failed("Checkout is unavailable. Please try again.")
            return
        }

        cancelCheckoutConfirmation()
        hireCheckoutCoachUID = coachUID
        hireCheckoutState = .creatingCheckout

        do {
            let chargesEnabled = try await firestore.fetchCoachStripeChargesEnabled(
                coachFirestoreID: coachUID
            )
            liveStripeChargesEnabled[coachUID] = chargesEnabled
            guard chargesEnabled else {
                hireCheckoutState = .failed("This coach is still completing setup.")
                return
            }

            let result = try await Functions.functions()
                .httpsCallable("createCheckoutSession")
                .call(["coachUid": coachUID])
            guard let response = result.data as? [String: Any],
                  let rawURL = (response["url"] as? String) ?? (response["checkoutUrl"] as? String),
                  let checkoutURL = URL(string: rawURL) else {
                hireCheckoutState = .failed("Checkout couldn't be opened. Please try again.")
                return
            }
            openCheckout(checkoutURL, coachUID: coachUID)
        } catch {
            if let chargesEnabled = try? await firestore.fetchCoachStripeChargesEnabled(
                coachFirestoreID: coachUID
            ), !chargesEnabled {
                liveStripeChargesEnabled[coachUID] = false
                hireCheckoutState = .failed("This coach is still completing setup.")
                return
            }
            hireCheckoutState = .failed(error.localizedDescription)
        }
    }

    func resetHireCheckoutMessage(for coachUID: String) {
        guard hireCheckoutCoachUID == coachUID else { return }
        switch hireCheckoutState {
        case .canceled, .failed, .confirmed, .confirmationTimedOut:
            hireCheckoutState = .idle
        default:
            break
        }
    }

    /// One-shot re-check after the confirmation timeout fallback. Still trusts
    /// only an active `coach_clients` document — never invents a local hire.
    func refreshHireCheckoutConfirmation() async {
        guard let coachUID = hireCheckoutCoachUID,
              hireCheckoutState == .confirmationTimedOut else { return }
        guard let clientUID = Auth.auth().currentUser?.uid, let firestore else {
            hireCheckoutState = .failed("Sign in to confirm this checkout.")
            return
        }

        do {
            if let connection = try await firestore.fetchClientCoachConnection(
                clientUserID: clientUID,
                coachFirestoreID: coachUID
            ), connection.isActive {
                await completeConfirmedCheckout(coachUID: coachUID)
            }
        } catch {
            hireCheckoutState = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    /// Simulator/manual helper: enter confirmation and force the timeout fallback
    /// without waiting the full 15 seconds.
    func debugSimulateConfirmationTimeoutFallback(coachUID: String) {
        CoachCheckoutConfirmationTiming.forceImmediateTimeout = true
        cancelCheckoutConfirmation()
        hireCheckoutCoachUID = coachUID
        hireCheckoutState = .confirming
        scheduleConfirmationTimeout(coachUID: coachUID)
    }

    /// Simulator/manual helper: exercise the confirming → hired transition path
    /// using the same Firestore-backed completion used by the live listener.
    func debugSimulateConfirmationSuccess(coachUID: String) async {
        cancelCheckoutConfirmation()
        hireCheckoutCoachUID = coachUID
        hireCheckoutState = .confirming
        await completeConfirmedCheckout(coachUID: coachUID)
    }
    #endif

    private func openCheckout(_ url: URL, coachUID: String) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "syncfit"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self, self.hireCheckoutCoachUID == coachUID else { return }
                self.checkoutSession = nil

                if let authenticationError = error as? ASWebAuthenticationSessionError,
                   authenticationError.code == .canceledLogin {
                    self.hireCheckoutState = .canceled
                    return
                }
                if let error {
                    self.hireCheckoutState = .failed(error.localizedDescription)
                    return
                }
                guard let callbackURL else {
                    self.hireCheckoutState = .failed("Checkout couldn't be confirmed.")
                    return
                }
                switch CoachCheckoutCallbackValidator.result(for: callbackURL) {
                case .canceled:
                    self.hireCheckoutState = .canceled
                    return
                case .invalid:
                    self.hireCheckoutState = .failed("Checkout returned an invalid callback.")
                    return
                case .success:
                    self.startCheckoutConfirmation(coachUID: coachUID)
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        checkoutSession = session
        hireCheckoutState = .authenticating
        if !session.start() {
            checkoutSession = nil
            hireCheckoutState = .failed("Checkout couldn't be opened. Please try again.")
        }
    }

    private func startCheckoutConfirmation(coachUID: String) {
        guard let clientUID = Auth.auth().currentUser?.uid, let firestore else {
            hireCheckoutState = .failed("Sign in to confirm this checkout.")
            return
        }

        cancelCheckoutConfirmation()
        hireCheckoutState = .confirming
        coachConnectionListener = firestore.observeActiveCoachClientConnection(
            clientUserID: clientUID,
            coachFirestoreID: coachUID,
            onActive: { [weak self] in
                Task { @MainActor in
                    guard let self, self.hireCheckoutCoachUID == coachUID else { return }
                    await self.completeConfirmedCheckout(coachUID: coachUID)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.hireCheckoutCoachUID == coachUID else { return }
                    self.cancelCheckoutConfirmation()
                    self.hireCheckoutState = .failed(error.localizedDescription)
                }
            }
        )
        guard coachConnectionListener != nil else {
            hireCheckoutState = .failed("Checkout confirmation is unavailable.")
            return
        }

        scheduleConfirmationTimeout(coachUID: coachUID)
    }

    private func scheduleConfirmationTimeout(coachUID: String) {
        checkoutConfirmationTimeoutTask?.cancel()
        let timeoutNanoseconds = CoachCheckoutConfirmationTiming.timeoutNanoseconds
        checkoutConfirmationTimeoutTask = Task { [weak self] in
            if timeoutNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.hireCheckoutCoachUID == coachUID,
                      self.hireCheckoutState == .confirming else { return }
                self.cancelCheckoutConfirmation()
                self.hireCheckoutState = .confirmationTimedOut
            }
        }
    }

    private func completeConfirmedCheckout(coachUID: String) async {
        cancelCheckoutConfirmation()
        await refreshClientCoachConnection()
        guard hireCheckoutCoachUID == coachUID else { return }
        // Hired UI still requires an active coach_clients doc via refresh above.
        hireCheckoutState = .confirmed
    }

    private func cancelCheckoutConfirmation() {
        coachConnectionListener?.remove()
        coachConnectionListener = nil
        checkoutConfirmationTimeoutTask?.cancel()
        checkoutConfirmationTimeoutTask = nil
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
        guard let firestore else {
            print("[CoachSave] Marketplace refresh skipped — Firestore unavailable")
            return
        }
        do {
            let remote = try await firestore.fetchCoachProfiles().map { $0.sanitizedForDisplay() }
            // Prefer cloud listings. Keep any local-only seed that isn't already
            // represented by a remote coachUserID (avoids hiding real coaches behind mocks).
            let remoteUIDs = Set(remote.compactMap(\.coachUserID))
            let localOnly = marketplaceCoaches.filter { coach in
                guard let uid = coach.coachUserID, !uid.isEmpty else {
                    // Untagged local mock — keep only if no remote coaches yet.
                    return remote.isEmpty
                }
                return !remoteUIDs.contains(uid)
            }
            marketplaceCoaches = (remote + localOnly).map { $0.sanitizedForDisplay() }
            print("[CoachSave] Marketplace now has \(marketplaceCoaches.count) coaches (remote=\(remote.count))")

            let coachKey = portalProfile.coachUserID.isEmpty
                ? (Auth.auth().currentUser?.uid ?? portalProfile.id.uuidString)
                : portalProfile.coachUserID
            clientConnections = try await firestore.fetchCoachClientConnections(coachFirestoreID: coachKey)
        } catch {
            print("[CoachSave] Marketplace refresh FAILED: \(error)")
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

extension CoachService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }
}
