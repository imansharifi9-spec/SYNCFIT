import Foundation
import FirebaseAuth
import FirebaseFirestore

struct FirestoreUserProfile: Codable {
    var hasCompletedOnboarding: Bool
    var profileName: String
    var goalRaw: String
    var experienceRaw: String
    var calorieTarget: Int
    var proteinTarget: Int
    var carbTarget: Int
    var fatTarget: Int
    var genderRaw: String
    var birthday: Date
    var heightCm: Double
    var bodyWeightKg: Double
    var measurementSystemRaw: String
    var activityLevelRaw: String
    var hasCoach: Bool
    var hasCompletedProgramSetup: Bool
    var workoutScheduleJSON: String
    var ownerUserID: String
    var isCoach: Bool
    var coachActivatedAt: Date?
    var photoFileName: String?
    var photoURL: String?

    static let empty = FirestoreUserProfile(
        hasCompletedOnboarding: false,
        profileName: "",
        goalRaw: FitnessGoal.healthyLifestyle.rawValue,
        experienceRaw: ExperienceLevel.beginner.rawValue,
        calorieTarget: 2200,
        proteinTarget: 150,
        carbTarget: 220,
        fatTarget: 70,
        genderRaw: Gender.preferNotToSay.rawValue,
        birthday: Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now,
        heightCm: 175,
        bodyWeightKg: 75,
        measurementSystemRaw: MeasurementSystem.imperial.rawValue,
        activityLevelRaw: ActivityLevel.moderatelyActive.rawValue,
        hasCoach: false,
        hasCompletedProgramSetup: false,
        workoutScheduleJSON: "",
        ownerUserID: "",
        isCoach: false,
        coachActivatedAt: nil,
        photoFileName: nil,
        photoURL: nil
    )

    func asUserProfile() -> UserProfile {
        var profile = UserProfile()
        profile.name = profileName
        profile.goal = FitnessGoal.fromStored(goalRaw)
        profile.experienceLevel = ExperienceLevel(rawValue: experienceRaw) ?? .beginner
        profile.calorieTarget = calorieTarget
        profile.proteinTarget = proteinTarget
        profile.carbTarget = carbTarget
        profile.fatTarget = fatTarget
        profile.gender = Gender(rawValue: genderRaw) ?? .preferNotToSay
        profile.birthday = birthday
        profile.heightCm = heightCm
        profile.bodyWeightKg = bodyWeightKg
        profile.measurementSystem = MeasurementSystem(rawValue: measurementSystemRaw) ?? .imperial
        profile.activityLevel = ActivityLevel(rawValue: activityLevelRaw) ?? .moderatelyActive
        profile.hasCoach = hasCoach
        profile.photoFileName = photoFileName
        profile.photoURL = photoURL
        return profile
    }
}

struct CoachCodeRecord {
    let documentID: String
    let codeHash: String
    let userID: String
    let isActive: Bool
    let activatedAt: Date?
}

enum CoachCodeActivationError: LocalizedError {
    case notAuthenticated
    case notFound
    case revoked
    case userMismatch

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Sign in to your SyncFit account first, then enter your coach code."
        case .notFound:
            return "Invalid or expired code. Contact SyncFit for access."
        case .revoked:
            return "This code has been revoked. Contact SyncFit."
        case .userMismatch:
            return "Invalid or expired code. Contact SyncFit for access."
        }
    }
}

enum FirestoreDatabaseError: LocalizedError {
    case notAuthenticated
    case firebaseUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be signed in to sync data."
        case .firebaseUnavailable:
            return "Firebase is not configured on this build."
        case .encodingFailed:
            return "Could not encode data for cloud sync."
        }
    }
}

@MainActor
final class FirestoreDatabaseManager: ObservableObject {
    var isAvailable: Bool {
        FirebaseConfiguration.isConfigured
    }

    private var db: Firestore? {
        guard FirebaseConfiguration.isConfigured else { return nil }
        return Firestore.firestore()
    }

    // MARK: - User profile

    struct FetchedUserProfile {
        let profile: FirestoreUserProfile
        /// True when the cloud document has never stored height/weight (pre-scoping schema).
        let missingBodyStatsInCloud: Bool
    }

    func fetchUserProfile() async throws -> FirestoreUserProfile {
        try await fetchUserProfileDetailed().profile
    }

    func fetchUserProfileDetailed() async throws -> FetchedUserProfile {
        let document = try await userDocument().getDocument()
        guard let data = document.data() else {
            return FetchedUserProfile(profile: .empty, missingBodyStatsInCloud: true)
        }
        return FetchedUserProfile(
            profile: decodeUserProfile(from: data),
            missingBodyStatsInCloud: data["heightCm"] == nil || data["bodyWeightKg"] == nil
        )
    }

    func saveUserProfile(
        _ profile: UserProfile,
        hasCompletedOnboarding: Bool,
        hasCompletedProgramSetup: Bool? = nil,
        workoutScheduleJSON: String? = nil
    ) async throws {
        let uid = try userID()
        var data: [String: Any] = [
            "hasCompletedOnboarding": hasCompletedOnboarding,
            "ownerUserID": uid,
            "profileName": profile.name,
            "goalRaw": profile.goal.rawValue,
            "experienceRaw": profile.experienceLevel.rawValue,
            "calorieTarget": profile.calorieTarget,
            "proteinTarget": profile.proteinTarget,
            "carbTarget": profile.carbTarget,
            "fatTarget": profile.fatTarget,
            "genderRaw": profile.gender.rawValue,
            "birthday": Timestamp(date: profile.birthday),
            "heightCm": profile.heightCm,
            "bodyWeightKg": profile.bodyWeightKg,
            "measurementSystemRaw": profile.measurementSystem.rawValue,
            "activityLevelRaw": profile.activityLevel.rawValue,
            "hasCoach": profile.hasCoach,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let hasCompletedProgramSetup {
            data["hasCompletedProgramSetup"] = hasCompletedProgramSetup
        }
        if let workoutScheduleJSON {
            data["workoutScheduleJSON"] = workoutScheduleJSON
        }
        if let photoFileName = profile.photoFileName, !photoFileName.isEmpty {
            data["photoFileName"] = photoFileName
        }
        if let photoURL = profile.photoURL, !photoURL.isEmpty {
            data["photoURL"] = photoURL
        }
        try await userDocument().setData(data, merge: true)
    }

    /// Phase-1 client write of StoreKit entitlement mirror. Logged by SubscriptionManager.
    /// TODO: After server-side receipt verification, move this write to Cloud Functions only.
    func saveSubscriptionStatus(status: String, expiresAt: Date?) async throws {
        let uid = try userID()
        var data: [String: Any] = [
            "subscriptionStatus": status,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let expiresAt {
            data["subscriptionExpiresAt"] = Timestamp(date: expiresAt)
        } else {
            data["subscriptionExpiresAt"] = NSNull()
        }
        let path = "users/\(uid)"
        print(
            "[Subscription] FirestoreDatabaseManager.setData merge path=\(path) " +
            "status=\(status) expiresAt=\(String(describing: expiresAt))"
        )
        do {
            try await userDocument().setData(data, merge: true)
            print("[Subscription] FirestoreDatabaseManager.setData OK path=\(path)")
        } catch {
            print("[Subscription] FirestoreDatabaseManager.setData FAILED path=\(path): \(error)")
            throw error
        }
    }

    /// Reads `subscriptionStatus` from `users/{uid}` for the signed-in user.
    func fetchSubscriptionStatus() async throws -> String? {
        let document = try await userDocument().getDocument()
        return document.data()?["subscriptionStatus"] as? String
    }

    func fetchUserCoachStatus() async throws -> (isCoach: Bool, coachActivatedAt: Date?) {
        let document = try await userDocument().getDocument()
        guard let data = document.data() else { return (false, nil) }
        return (
            data["isCoach"] as? Bool ?? false,
            timestampDate(from: data["coachActivatedAt"])
        )
    }

    func activateCoachOnUser(activatedAt: Date) async throws {
        try await userDocument().setData(
            [
                "isCoach": true,
                "coachActivatedAt": Timestamp(date: activatedAt),
                "updatedAt": FieldValue.serverTimestamp()
            ],
            merge: true
        )
    }

    // MARK: - Coach access codes

    func findCoachCode(hashedCode: String, userID: String, debugPlainCode: String? = nil) async throws -> CoachCodeRecord? {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }

        #if DEBUG
        if let debugPlainCode {
            let normalized = debugPlainCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            print("[CoachAuth] Entered code: \(debugPlainCode)")
            print("[CoachAuth] Normalized: \(normalized)")
            print("[CoachAuth] Hashed: \(hashedCode)")
            print("[CoachAuth] Current userId: \(userID)")
        }
        #endif

        let snapshot = try await db.collection("coach_codes")
            .whereField("code", isEqualTo: hashedCode)
            .whereField("userId", isEqualTo: userID)
            .limit(to: 1)
            .getDocuments()

        #if DEBUG
        print("[CoachAuth] Firestore query result count: \(snapshot.documents.count)")
        if let first = snapshot.documents.first {
            print("[CoachAuth] Matched document: \(first.documentID) userId=\(first.data()["userId"] ?? "nil") isActive=\(first.data()["isActive"] ?? "nil")")
        }
        #endif

        guard let document = snapshot.documents.first else { return nil }
        return decodeCoachCode(from: document.data(), documentID: document.documentID)
    }

    func markCoachCodeActivated(documentID: String, activatedAt: Date) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        try await db.collection("coach_codes").document(documentID).updateData([
            "activatedAt": Timestamp(date: activatedAt)
        ])
    }

    func activateCoachAccessCode(_ plainCode: String) async throws {
        let uid = try userID()
        let hashed = CoachAuthCrypto.sha256Hex(plainCode)

        guard let record = try await findCoachCode(hashedCode: hashed, userID: uid, debugPlainCode: plainCode) else {
            #if DEBUG
            print("[CoachAuth] No matching coach_codes document for this code + userId")
            #endif
            throw CoachCodeActivationError.notFound
        }

        guard record.userID == uid else {
            throw CoachCodeActivationError.userMismatch
        }

        guard record.isActive else {
            throw CoachCodeActivationError.revoked
        }

        let now = Date()
        if record.activatedAt == nil {
            try await markCoachCodeActivated(documentID: record.documentID, activatedAt: now)
            try await activateCoachOnUser(activatedAt: now)
        } else {
            let status = try await fetchUserCoachStatus()
            if !status.isCoach {
                try await activateCoachOnUser(activatedAt: record.activatedAt ?? now)
            }
        }
    }

    #if DEBUG
    /// Seeds (or refreshes) the dev coach code for the signed-in test account.
    /// Remove before production.
    func seedDevCoachCode() async {
        guard let db else {
            print("[CoachDevSeed] Firebase not configured — skipping seed")
            return
        }
        guard let userId = Auth.auth().currentUser?.uid else {
            print("[CoachDevSeed] No signed-in user — skipping seed")
            return
        }

        let hashedCode = CoachAuthCrypto.sha256Hex("iman2005")
        let docRef = db.collection("coach_codes").document("dev_code")

        do {
            let existing = try await docRef.getDocument()
            if existing.exists {
                try await docRef.setData(
                    [
                        "code": hashedCode,
                        "userId": userId,
                        "isActive": true
                    ],
                    merge: true
                )
                print("[CoachDevSeed] Refreshed dev_code userId for: \(userId)")
                return
            }

            try await docRef.setData([
                "code": hashedCode,
                "userId": userId,
                "isActive": true,
                "activatedAt": NSNull(),
                "createdAt": FieldValue.serverTimestamp()
            ])
            print("[CoachDevSeed] Seeded dev_code (hash: \(hashedCode.prefix(12))…) for userId: \(userId)")
        } catch {
            print("[CoachDevSeed] Failed to seed dev_code: \(error.localizedDescription)")
        }
    }
    #endif

    // MARK: - Weight

    func saveWeight(_ entry: WeightEntry) async throws {
        try await weightsCollection()
            .document(entry.id.uuidString)
            .setData(weightPayload(entry))
    }

    func fetchWeights() async throws -> [WeightEntry] {
        let snapshot = try await weightsCollection()
            .order(by: "date", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { decodeWeight(from: $0.data()) }
    }

    func deleteWeight(_ entry: WeightEntry) async throws {
        try await weightsCollection().document(entry.id.uuidString).delete()
    }

    // MARK: - Meals

    func saveMeal(_ entry: FoodEntry) async throws {
        try await mealsCollection()
            .document(entry.id.uuidString)
            .setData(mealPayload(entry))
    }

    func fetchMeals() async throws -> [FoodEntry] {
        let snapshot = try await mealsCollection()
            .order(by: "date", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { decodeMeal(from: $0.data()) }
    }

    func deleteMeal(_ entry: FoodEntry) async throws {
        try await mealsCollection().document(entry.id.uuidString).delete()
    }

    // MARK: - Workouts

    func saveWorkout(_ entry: WorkoutEntry) async throws {
        let path = "users/\(try userID())/workouts/\(entry.id.uuidString)"
        print("[WorkoutSync] Writing \(path) exercise=\(entry.exercise.name) planned=\(entry.plannedSets.count) sets=\(entry.sets.count)")
        do {
            try await workoutsCollection()
                .document(entry.id.uuidString)
                .setData(workoutPayload(entry))
            print("[WorkoutSync] Write OK \(path)")
        } catch {
            print("[WorkoutSync] Write FAILED \(path): \(error)")
            throw error
        }
    }

    func fetchWorkouts() async throws -> [WorkoutEntry] {
        let uid = try userID()
        print("[WorkoutSync] Listing users/\(uid)/workouts")
        do {
            let snapshot = try await workoutsCollection()
                .order(by: "date", descending: true)
                .getDocuments()
            let decoded = snapshot.documents.compactMap { decodeWorkout(from: $0.data()) }
            print("[WorkoutSync] List OK count=\(decoded.count)")
            return decoded
        } catch {
            print("[WorkoutSync] List FAILED users/\(uid)/workouts: \(error)")
            throw error
        }
    }

    func deleteWorkout(_ entry: WorkoutEntry) async throws {
        let path = "users/\(try userID())/workouts/\(entry.id.uuidString)"
        print("[WorkoutSync] Deleting \(path)")
        do {
            try await workoutsCollection().document(entry.id.uuidString).delete()
            print("[WorkoutSync] Delete OK \(path)")
        } catch {
            print("[WorkoutSync] Delete FAILED \(path): \(error)")
            throw error
        }
    }

    func fetchAllUserData() async throws -> (weights: [WeightEntry], meals: [FoodEntry], workouts: [WorkoutEntry]) {
        async let weights = fetchWeights()
        async let meals = fetchMeals()
        async let workouts = fetchWorkouts()
        return try await (weights, meals, workouts)
    }

    // MARK: - Routines (schedule content — referenced by customRoutineID)

    func saveRoutine(_ routine: WorkoutRoutine) async throws {
        let path = "users/\(try userID())/routines/\(routine.id.uuidString)"
        print("[WorkoutSync] PART2 Writing routine content \(path) name=\(routine.name) exercises=\(routine.exercises.count)")
        do {
            try await routinesCollection()
                .document(routine.id.uuidString)
                .setData(routinePayload(routine))
            print("[WorkoutSync] PART2 Write OK \(path)")
        } catch {
            print("[WorkoutSync] PART2 Write FAILED \(path): \(error)")
            throw error
        }
    }

    func fetchRoutines() async throws -> [WorkoutRoutine] {
        let uid = try userID()
        print("[WorkoutSync] Listing users/\(uid)/routines")
        do {
            let snapshot = try await routinesCollection().getDocuments()
            let decoded = snapshot.documents.compactMap { decodeRoutine(from: $0.data()) }
            print("[WorkoutSync] List routines OK count=\(decoded.count)")
            return decoded
        } catch {
            print("[WorkoutSync] List routines FAILED users/\(uid)/routines: \(error)")
            throw error
        }
    }

    func deleteRoutine(_ routine: WorkoutRoutine) async throws {
        let path = "users/\(try userID())/routines/\(routine.id.uuidString)"
        print("[WorkoutSync] Deleting routine \(path)")
        do {
            try await routinesCollection().document(routine.id.uuidString).delete()
            print("[WorkoutSync] Delete routine OK \(path)")
        } catch {
            print("[WorkoutSync] Delete routine FAILED \(path): \(error)")
            throw error
        }
    }

    // MARK: - Coaches marketplace

    func saveCoachProfile(_ profile: CoachProfile) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        // Marketplace + security rules require the document ID to be the Auth UID.
        // Never fall back to a random UUID — that path fails rules and never appears
        // in other users' marketplace queries keyed by coachId/uid.
        let authUID = try userID()
        let coachDocumentID = authUID
        let path = "coaches/\(coachDocumentID)"
        var data: [String: Any] = [
            "id": profile.id.uuidString,
            "coachId": coachDocumentID,
            "name": profile.name,
            "specialty": profile.specialty,
            "pricePerMonth": profile.pricePerMonth,
            "isOnline": profile.isOnline,
            "rating": profile.rating,
            "bio": profile.bio,
            "clientCount": profile.clientCount,
            "reviewCount": profile.reviewCount,
            "isVerified": profile.isVerified,
            "availability": profile.availability.rawValue,
            "location": profile.location,
            "specialties": profile.specialties,
            "isLive": profile.isLive,
            "isListed": profile.isListed,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let photoFileName = profile.photoFileName, !photoFileName.isEmpty {
            data["photoFileName"] = photoFileName
        }
        if let photoURL = profile.photoURL, !photoURL.isEmpty {
            data["photoURL"] = photoURL
        }
        print("[CoachSave] Writing \(path) name=\(profile.name) isLive=\(profile.isLive) isListed=\(profile.isListed) specialties=\(profile.specialties) rate=\(profile.pricePerMonth)")
        do {
            try await db.collection("coaches").document(coachDocumentID).setData(data, merge: true)
            print("[CoachSave] Write OK \(path)")
        } catch {
            print("[CoachSave] Write FAILED \(path): \(error)")
            throw error
        }
    }

    func fetchCoachProfiles() async throws -> [CoachProfile] {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        print("[CoachSave] Listing coaches where isLive==true")
        do {
            let snapshot = try await db.collection("coaches")
                .whereField("isLive", isEqualTo: true)
                .getDocuments()
            let decoded = snapshot.documents.compactMap { doc -> CoachProfile? in
                let profile = decodeCoachProfile(from: doc.data())
                if profile == nil {
                    print("[CoachSave] Decode DROPPED coaches/\(doc.documentID) keys=\(Array(doc.data().keys).sorted())")
                }
                return profile
            }
            let listed = decoded.filter(\.isListed)
            print("[CoachSave] List OK raw=\(snapshot.documents.count) decoded=\(decoded.count) listed=\(listed.count)")
            return listed
        } catch {
            print("[CoachSave] List FAILED: \(error)")
            throw error
        }
    }

    /// Loads the signed-in coach's own marketplace document (even if not live yet).
    func fetchCoachProfile(coachFirestoreID: String) async throws -> CoachProfile? {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let path = "coaches/\(coachFirestoreID)"
        print("[CoachSave] Fetching \(path)")
        do {
            let document = try await db.collection("coaches").document(coachFirestoreID).getDocument()
            guard let data = document.data() else {
                print("[CoachSave] \(path) missing")
                return nil
            }
            let profile = decodeCoachProfile(from: data)
            if profile == nil {
                print("[CoachSave] Decode DROPPED \(path) keys=\(Array(data.keys).sorted())")
            } else {
                print("[CoachSave] Fetch OK \(path) name=\(profile?.name ?? "")")
            }
            return profile
        } catch {
            print("[CoachSave] Fetch FAILED \(path): \(error)")
            throw error
        }
    }

    /// Reads payment readiness from the server so a cached marketplace profile can
    /// never authorize a Checkout attempt.
    func fetchCoachStripeChargesEnabled(coachFirestoreID: String) async throws -> Bool {
        try await fetchCoachStripeStatus(coachFirestoreID: coachFirestoreID).chargesEnabled
    }

    /// Server-only read of Connect readiness for `coaches/{uid}`.
    func fetchCoachStripeStatus(coachFirestoreID: String) async throws -> CoachStripeStatus {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let document = try await db.collection("coaches")
            .document(coachFirestoreID)
            .getDocument(source: .server)
        let data = document.data() ?? [:]
        let accountId = (data["stripeConnectedAccountId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let charges = data["stripeChargesEnabled"] as? Bool ?? false
        // DEBUG: raw Firestore payload the client actually received from the server.
        print(
            "[StripeConnect] fetchCoachStripeStatus raw uid=\(coachFirestoreID) exists=\(document.exists) stripeChargesEnabled=\(String(describing: data["stripeChargesEnabled"])) chargesParsed=\(charges) accountId=\(accountId.isEmpty ? "nil" : accountId)"
        )
        return CoachStripeStatus(
            chargesEnabled: charges,
            hasConnectedAccount: !accountId.isEmpty
        )
    }

    func observeCoachStripeChargesEnabled(
        coachFirestoreID: String,
        onChange: @escaping (Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        observeCoachStripeStatus(
            coachFirestoreID: coachFirestoreID,
            onChange: { status in onChange(status.chargesEnabled) },
            onError: onError
        )
    }

    /// Live Connect readiness for a coach document (`chargesEnabled` + connected account id).
    func observeCoachStripeStatus(
        coachFirestoreID: String,
        onChange: @escaping (CoachStripeStatus) -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("coaches").document(coachFirestoreID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    onError(error)
                    return
                }
                let data = snapshot?.data() ?? [:]
                let accountId = (data["stripeConnectedAccountId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                onChange(
                    CoachStripeStatus(
                        chargesEnabled: data["stripeChargesEnabled"] as? Bool ?? false,
                        hasConnectedAccount: !accountId.isEmpty
                    )
                )
            }
    }

    /// Querying only the client participant avoids a compound index; coach and
    /// status are deliberately filtered client-side.
    func observeActiveCoachSubscription(
        clientUserID: String,
        coachFirestoreID: String,
        onActive: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("coachSubscriptions")
            .whereField("clientUid", isEqualTo: clientUserID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    onError(error)
                    return
                }
                let hasActiveMatch = snapshot?.documents.contains { document in
                    let data = document.data()
                    return data["coachUid"] as? String == coachFirestoreID
                        && data["status"] as? String == "active"
                } ?? false
                if hasActiveMatch {
                    onActive()
                }
            }
    }

    /// Hire confirmation listens on the canonical paid connection document so the
    /// UI only flips after the webhook writes `coach_clients/{sorted(client,coach)}`.
    func observeActiveCoachClientConnection(
        clientUserID: String,
        coachFirestoreID: String,
        onActive: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        let documentID = CoachClientConnection.makeDocumentID(
            clientUserID: clientUserID,
            coachFirestoreID: coachFirestoreID
        )
        return db.collection("coach_clients").document(documentID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    onError(error)
                    return
                }
                guard let data = snapshot?.data(),
                      let status = data["status"] as? String,
                      status == CoachConnectionStatus.active.rawValue else {
                    return
                }
                onActive()
            }
    }

    func saveCoachClientConnection(_ connection: CoachClientConnection) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let coachKey = connection.coachFirestoreID
        // Rules resolve the edge via get(coach_clients/{sorted(client, coachAuthUid)}).
        // Always write to that canonical id so coach reads cannot miss a legacy doc.
        let canonicalDocID = CoachClientConnection.makeDocumentID(
            clientUserID: connection.clientUserID,
            coachFirestoreID: coachKey
        )
        if connection.documentID != canonicalDocID {
            print(
                "[CoachClientData] Repairing connection doc id " +
                "from=\(connection.documentID) to=\(canonicalDocID) " +
                "client=\(connection.clientUserID) coach=\(coachKey)"
            )
        }
        let data: [String: Any] = [
            "coachId": coachKey,
            "clientId": connection.clientUserID,
            "clientUserID": connection.clientUserID,
            "coachName": connection.coachName,
            "clientName": connection.clientName,
            "connectedAt": Timestamp(date: connection.connectedAt),
            "permissions": [
                "workouts": connection.shareWorkouts,
                "nutrition": connection.shareNutrition,
                "progress": connection.shareProgress
            ],
            "shareWorkouts": connection.shareWorkouts,
            "shareNutrition": connection.shareNutrition,
            "shareProgress": connection.shareProgress,
            "status": connection.status.rawValue,
            "clientInitiatedContact": connection.clientInitiatedContact,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        print(
            "[CoachClientData] Saving coach_clients/\(canonicalDocID) " +
            "permissions workouts=\(connection.shareWorkouts) " +
            "nutrition=\(connection.shareNutrition) progress=\(connection.shareProgress)"
        )
        do {
            try await db.collection("coach_clients")
                .document(canonicalDocID)
                .setData(data, merge: true)
            // Best-effort cleanup of a legacy non-canonical doc so rules + queries agree.
            if connection.documentID != canonicalDocID {
                try? await db.collection("coach_clients")
                    .document(connection.documentID)
                    .delete()
            }
            print("[CoachClientData] Save OK coach_clients/\(canonicalDocID)")
        } catch {
            print("[CoachClientData] Save FAILED coach_clients/\(canonicalDocID): \(error)")
            throw error
        }
    }

    func fetchCoachClientConnections(coachFirestoreID: String) async throws -> [CoachClientConnection] {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let snapshot = try await db.collection("coach_clients")
            .whereField("coachId", isEqualTo: coachFirestoreID)
            .whereField("status", isEqualTo: CoachConnectionStatus.active.rawValue)
            .getDocuments()
        return snapshot.documents.compactMap { decodeCoachClientConnection(from: $0.data(), documentID: $0.documentID) }
    }

    func fetchClientCoachConnection(clientUserID: String) async throws -> CoachClientConnection? {
        let connections = try await fetchActiveClientConnections(clientUserID: clientUserID)
        return connections.first
    }

    func fetchActiveClientConnections(clientUserID: String) async throws -> [CoachClientConnection] {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let snapshot = try await db.collection("coach_clients")
            .whereField("clientUserID", isEqualTo: clientUserID)
            .whereField("status", isEqualTo: CoachConnectionStatus.active.rawValue)
            .getDocuments()
        return snapshot.documents.compactMap {
            decodeCoachClientConnection(from: $0.data(), documentID: $0.documentID)
        }
    }

    func fetchClientCoachConnection(clientUserID: String, coachFirestoreID: String) async throws -> CoachClientConnection? {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let documentID = CoachClientConnection.makeDocumentID(
            clientUserID: clientUserID,
            coachFirestoreID: coachFirestoreID
        )
        let document = try await db.collection("coach_clients").document(documentID).getDocument()
        guard document.exists, let data = document.data() else { return nil }
        let connection = decodeCoachClientConnection(from: data, documentID: document.documentID)
        return connection?.isActive == true ? connection : nil
    }

    /// Ensures `coach_clients/{sorted(client, coachAuthUid)}` exists with the fields
    /// security rules require. Skips rewrite when the canonical doc is already valid
    /// so listener setup does not churn a write under active coach reads.
    func ensureCanonicalCoachClientConnection(
        from connection: CoachClientConnection,
        coachAuthUID: String
    ) async throws -> CoachClientConnection {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let clientUID = connection.clientUserID
        let canonicalID = CoachClientConnection.makeDocumentID(
            clientUserID: clientUID,
            coachFirestoreID: coachAuthUID
        )
        let canonicalRef = db.collection("coach_clients").document(canonicalID)

        print("[CoachClientData] ensureCanonical path=coach_clients/\(canonicalID)")

        // Prefer share flags from a readable legacy/list doc, then in-memory connection.
        var source = connection
        source.clientUserID = clientUID
        source.coachFirestoreID = coachAuthUID
        source.documentID = canonicalID
        source.status = .active

        // 1) Read the doc the coach already has in their clients list (known readable).
        if connection.documentID != canonicalID, !connection.documentID.isEmpty {
            do {
                let legacy = try await db.collection("coach_clients")
                    .document(connection.documentID)
                    .getDocument()
                if let data = legacy.data(),
                   let decoded = decodeCoachClientConnection(from: data, documentID: legacy.documentID),
                   decoded.isActive {
                    print(
                        "[CoachClientData] Loaded list doc=\(decoded.documentID) " +
                        "shareW=\(decoded.shareWorkouts) shareN=\(decoded.shareNutrition) " +
                        "shareP=\(decoded.shareProgress)"
                    )
                    source.shareWorkouts = decoded.shareWorkouts || source.shareWorkouts
                    source.shareNutrition = decoded.shareNutrition || source.shareNutrition
                    source.shareProgress = decoded.shareProgress || source.shareProgress
                    if source.clientName.isEmpty { source.clientName = decoded.clientName }
                    if source.coachName.isEmpty { source.coachName = decoded.coachName }
                }
            } catch {
                print("[CoachClientData] Legacy doc read skipped: \(error.localizedDescription)")
            }
        }

        // 2) Read canonical if it exists.
        var canonicalReady = false
        do {
            let snap = try await canonicalRef.getDocument()
            if let data = snap.data(),
               let decoded = decodeCoachClientConnection(from: data, documentID: canonicalID),
               decoded.isActive,
               decoded.coachFirestoreID == coachAuthUID {
                print(
                    "[CoachClientData] Canonical EXISTS coachId=\(decoded.coachFirestoreID) " +
                    "shareW=\(decoded.shareWorkouts) shareN=\(decoded.shareNutrition) " +
                    "shareP=\(decoded.shareProgress) keys=\(Array(data.keys).sorted())"
                )
                if let permissions = data["permissions"] as? [String: Any] {
                    print("[CoachClientData] Canonical permissions map=\(permissions)")
                }
                source.shareWorkouts = decoded.shareWorkouts || source.shareWorkouts
                source.shareNutrition = decoded.shareNutrition || source.shareNutrition
                source.shareProgress = decoded.shareProgress || source.shareProgress
                if source.clientName.isEmpty { source.clientName = decoded.clientName }
                if source.coachName.isEmpty { source.coachName = decoded.coachName }

                let sharesOK = source.shareWorkouts || source.shareNutrition || source.shareProgress
                let flagsMatchDoc =
                    decoded.shareWorkouts == source.shareWorkouts
                    && decoded.shareNutrition == source.shareNutrition
                    && decoded.shareProgress == source.shareProgress
                if sharesOK && flagsMatchDoc {
                    print("[CoachClientData] Canonical already valid — skip rewrite")
                    return decoded
                }
                canonicalReady = true
            } else {
                print("[CoachClientData] Canonical missing or coachId mismatch — will create/repair")
            }
        } catch {
            print("[CoachClientData] Canonical get failed (will still write): \(error.localizedDescription)")
        }

        // 3) Write only when missing, wrong coachId, or share flags need repair.
        print(
            "[CoachClientData] Writing canonical (repair=\(canonicalReady)) shareW=\(source.shareWorkouts) " +
            "shareN=\(source.shareNutrition) shareP=\(source.shareProgress)"
        )
        try await saveCoachClientConnection(source)

        let live = try await fetchClientCoachConnection(
            clientUserID: clientUID,
            coachFirestoreID: coachAuthUID
        ) ?? source

        print(
            "[CoachClientData] ensureCanonical DONE doc=\(live.documentID) " +
            "coachId=\(live.coachFirestoreID) shareW=\(live.shareWorkouts) " +
            "shareN=\(live.shareNutrition) shareP=\(live.shareProgress)"
        )
        return live
    }

    func observeClientWorkouts(
        clientUserID: String,
        onChange: @escaping ([WorkoutEntry]) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        let path = "users/\(clientUserID)/workouts"
        print("[CoachClientData] Listen START \(path) coach=\(Auth.auth().currentUser?.uid ?? "nil")")
        return db.collection("users").document(clientUserID).collection("workouts")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[CoachClientData] Listen FAILED \(path): \(error)")
                    // Do not onChange([]) — teardown/cancel and transient denies were
                    // wiping a successful snapshot and flashing an empty UI.
                    onError?(error)
                    return
                }
                let workouts = snapshot?.documents.compactMap { self.decodeWorkout(from: $0.data()) } ?? []
                print("[CoachClientData] Listen OK \(path) count=\(workouts.count)")
                onChange(workouts)
            }
    }

    func observeClientMeals(
        clientUserID: String,
        onChange: @escaping ([FoodEntry]) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        let path = "users/\(clientUserID)/meals"
        print("[CoachClientData] Listen START \(path) coach=\(Auth.auth().currentUser?.uid ?? "nil")")
        return db.collection("users").document(clientUserID).collection("meals")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[CoachClientData] Listen FAILED \(path): \(error)")
                    onError?(error)
                    return
                }
                let meals = snapshot?.documents.compactMap { self.decodeMeal(from: $0.data()) } ?? []
                print("[CoachClientData] Listen OK \(path) count=\(meals.count)")
                onChange(meals)
            }
    }

    func observeClientWeights(
        clientUserID: String,
        onChange: @escaping ([WeightEntry]) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        let path = "users/\(clientUserID)/weights"
        print("[CoachClientData] Listen START \(path) coach=\(Auth.auth().currentUser?.uid ?? "nil")")
        return db.collection("users").document(clientUserID).collection("weights")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[CoachClientData] Listen FAILED \(path): \(error)")
                    onError?(error)
                    return
                }
                let weights = snapshot?.documents.compactMap { self.decodeWeight(from: $0.data()) } ?? []
                print("[CoachClientData] Listen OK \(path) count=\(weights.count)")
                onChange(weights)
            }
    }

    func observeClientProgressPhotos(
        clientUserID: String,
        onChange: @escaping ([ProgressPhotoEntry]) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        let path = "users/\(clientUserID)/progress_photos"
        print("[CoachClientData] Listen START \(path) coach=\(Auth.auth().currentUser?.uid ?? "nil")")
        return db.collection("users").document(clientUserID).collection("progress_photos")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[CoachClientData] Listen FAILED \(path): \(error)")
                    onError?(error)
                    return
                }
                let photos = snapshot?.documents.compactMap { self.decodeProgressPhoto(from: $0.data()) } ?? []
                print("[CoachClientData] Listen OK \(path) count=\(photos.count)")
                onChange(photos)
            }
    }

    func observeClientProfile(
        clientUserID: String,
        onChange: @escaping (FirestoreUserProfile) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        let path = "users/\(clientUserID)"
        print("[CoachClientData] Listen START \(path) coach=\(Auth.auth().currentUser?.uid ?? "nil")")
        return db.collection("users").document(clientUserID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("[CoachClientData] Listen FAILED \(path): \(error)")
                    onError?(error)
                    return
                }
                let profile = snapshot?.data().map { self.decodeUserProfile(from: $0) } ?? .empty
                print("[CoachClientData] Listen OK \(path) name=\(profile.profileName)")
                onChange(profile)
            }
    }

    // MARK: - Progress photos (Firestore metadata)

    func saveProgressPhotoMetadata(_ entry: ProgressPhotoEntry) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let uid = try userID()
        let path = "users/\(uid)/progress_photos/\(entry.id.uuidString)"
        print("[ProgressPhoto] Writing metadata \(path)")
        do {
            try await db.collection("users").document(uid)
                .collection("progress_photos")
                .document(entry.id.uuidString)
                .setData(progressPhotoPayload(entry), merge: true)
            print("[ProgressPhoto] Metadata OK \(path)")
        } catch {
            print("[ProgressPhoto] Metadata FAILED \(path): \(error)")
            throw error
        }
    }

    func fetchProgressPhotos() async throws -> [ProgressPhotoEntry] {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let uid = try userID()
        let path = "users/\(uid)/progress_photos"
        print("[ProgressPhoto] Listing \(path)")
        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("progress_photos")
                .order(by: "date", descending: true)
                .getDocuments()
            let photos = snapshot.documents.compactMap { decodeProgressPhoto(from: $0.data()) }
            print("[ProgressPhoto] List OK count=\(photos.count)")
            return photos
        } catch {
            print("[ProgressPhoto] List FAILED \(path): \(error)")
            throw error
        }
    }

    func deleteProgressPhotoMetadata(_ entry: ProgressPhotoEntry) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let uid = try userID()
        let path = "users/\(uid)/progress_photos/\(entry.id.uuidString)"
        print("[ProgressPhoto] Deleting metadata \(path)")
        do {
            try await db.collection("users").document(uid)
                .collection("progress_photos")
                .document(entry.id.uuidString)
                .delete()
            print("[ProgressPhoto] Metadata delete OK \(path)")
        } catch {
            print("[ProgressPhoto] Metadata delete FAILED \(path): \(error)")
            throw error
        }
    }

    private func progressPhotoPayload(_ entry: ProgressPhotoEntry) -> [String: Any] {
        var data: [String: Any] = [
            "id": entry.id.uuidString,
            "date": Timestamp(date: entry.date),
            "fileName": entry.fileName,
            "userId": entry.userId,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let url = entry.downloadURL, !url.isEmpty {
            data["downloadURL"] = url
        }
        if let storagePath = entry.storagePath, !storagePath.isEmpty {
            data["storagePath"] = storagePath
        }
        return data
    }

    private func decodeProgressPhoto(from data: [String: Any]) -> ProgressPhotoEntry? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let fileName = data["fileName"] as? String,
              let date = timestampDate(from: data["date"]) else { return nil }
        return ProgressPhotoEntry(
            id: id,
            date: date,
            fileName: fileName,
            userId: data["userId"] as? String ?? "",
            downloadURL: data["downloadURL"] as? String,
            storagePath: data["storagePath"] as? String
        )
    }

    // MARK: - Coach routine templates

    func fetchCoachRoutineTemplates(coachFirestoreID: String) async throws -> [CoachRoutineTemplate] {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let snapshot = try await db.collection("coaches")
            .document(coachFirestoreID)
            .collection("routine_templates")
            .order(by: "updatedAt", descending: true)
            .getDocuments()
        return snapshot.documents.compactMap { decodeCoachRoutineTemplate(from: $0.data()) }
    }

    func saveCoachRoutineTemplate(_ template: CoachRoutineTemplate, coachFirestoreID: String) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        var updated = template
        updated.updatedAt = .now
        let data = try coachRoutineTemplatePayload(updated)
        try await db.collection("coaches")
            .document(coachFirestoreID)
            .collection("routine_templates")
            .document(template.id.uuidString)
            .setData(data, merge: true)
    }

    func deleteCoachRoutineTemplate(_ template: CoachRoutineTemplate, coachFirestoreID: String) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        try await db.collection("coaches")
            .document(coachFirestoreID)
            .collection("routine_templates")
            .document(template.id.uuidString)
            .delete()
    }

    private func coachRoutineTemplatePayload(_ template: CoachRoutineTemplate) throws -> [String: Any] {
        [
            "id": template.id.uuidString,
            "name": template.name,
            "days": template.days.map { day in
                [
                    "id": day.id.uuidString,
                    "weekday": day.weekday,
                    "dayLabel": day.dayLabel,
                    "isRest": day.isRest || day.exercises.isEmpty,
                    "exercises": day.exercises.map { exercise in
                        var payload: [String: Any] = [
                            "id": exercise.id.uuidString,
                            "name": exercise.name,
                            "muscleGroup": exercise.muscleGroup,
                            "setCount": exercise.setCount,
                            "reps": exercise.reps
                        ]
                        if let weight = exercise.weight {
                            payload["weight"] = weight
                        }
                        return payload
                    }
                ] as [String: Any]
            },
            "createdAt": Timestamp(date: template.createdAt),
            "updatedAt": Timestamp(date: template.updatedAt)
        ]
    }

    private func decodeCoachRoutineTemplate(from data: [String: Any]) -> CoachRoutineTemplate? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let daysData = data["days"] as? [[String: Any]] else {
            return nil
        }

        let days = daysData.compactMap { decodeCoachRoutineTemplateDay(from: $0) }
        let createdAt = timestampDate(from: data["createdAt"]) ?? .now
        let updatedAt = timestampDate(from: data["updatedAt"]) ?? createdAt

        return CoachRoutineTemplate(
            id: id,
            name: name,
            days: CoachRoutineTemplate.normalizedWeekdays(from: days),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decodeCoachRoutineTemplateDay(from data: [String: Any]) -> CoachRoutineTemplateDay? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let weekday = data["weekday"] as? Int,
              let dayLabel = data["dayLabel"] as? String else {
            return nil
        }

        let isRest = data["isRest"] as? Bool ?? false
        let exercisesData = data["exercises"] as? [[String: Any]] ?? []
        let exercises = exercisesData.compactMap { decodeCoachRoutineTemplateExercise(from: $0) }

        return CoachRoutineTemplateDay(
            id: id,
            weekday: weekday,
            dayLabel: dayLabel,
            isRest: isRest,
            exercises: exercises
        )
    }

    private func decodeCoachRoutineTemplateExercise(from data: [String: Any]) -> CoachRoutineTemplateExercise? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let muscleGroup = data["muscleGroup"] as? String else {
            return nil
        }

        let setCount = data["setCount"] as? Int ?? 3
        let reps = data["reps"] as? Int ?? 8
        let weight = data["weight"] as? Double

        return CoachRoutineTemplateExercise(
            id: id,
            name: name,
            muscleGroup: muscleGroup,
            setCount: setCount,
            reps: reps,
            weight: weight
        )
    }

    func saveCoachMessage(_ message: CoachMessage, coachFirestoreID: String, clientUserID: String?) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        // Rules require both coachId and clientUserID on create.
        guard let clientUserID, !clientUserID.isEmpty else {
            print("[ChatSync] Legacy coach_messages write skipped — missing clientUserID")
            throw FirestoreDatabaseError.notAuthenticated
        }
        let data: [String: Any] = [
            "id": message.id.uuidString,
            "conversationID": message.conversationID,
            "senderRole": message.senderRole.rawValue,
            "text": message.text,
            "sentAt": Timestamp(date: message.sentAt),
            "coachId": coachFirestoreID,
            "coachID": coachFirestoreID,
            "clientUserID": clientUserID
        ]
        print("[ChatSync] Legacy coach_messages write id=\(message.id.uuidString) coach=\(coachFirestoreID) client=\(clientUserID)")
        try await db.collection("coach_messages").document(message.id.uuidString).setData(data, merge: true)
    }

    func observeCoachMessages(
        conversationID: String,
        coachFirestoreID: String,
        onChange: @escaping ([CoachMessage]) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("coach_messages")
            .whereField("conversationID", isEqualTo: conversationID)
            .whereField("coachId", isEqualTo: coachFirestoreID)
            .order(by: "sentAt", descending: false)
            .addSnapshotListener { snapshot, _ in
                let messages = snapshot?.documents.compactMap { self.decodeCoachMessage(from: $0.data()) } ?? []
                onChange(messages)
            }
    }

    private func decodeCoachCode(from data: [String: Any], documentID: String) -> CoachCodeRecord? {
        guard let codeHash = data["code"] as? String,
              let userID = data["userId"] as? String else { return nil }

        return CoachCodeRecord(
            documentID: documentID,
            codeHash: codeHash,
            userID: userID,
            isActive: data["isActive"] as? Bool ?? false,
            activatedAt: timestampDate(from: data["activatedAt"])
        )
    }

    private func decodeCoachProfile(from data: [String: Any]) -> CoachProfile? {
        // Firestore often returns Int64 / NSNumber — never require `as? Int` / `as? Double`.
        guard let name = data["name"] as? String,
              let bio = data["bio"] as? String else { return nil }

        let id = (data["id"] as? String).flatMap(UUID.init(uuidString:))
            ?? (data["coachId"] as? String).flatMap { CoachAuthCrypto.stableCoachUUID(from: $0) }
            ?? UUID()
        let specialty = (data["specialty"] as? String)
            ?? (data["specialties"] as? [String])?.first
            ?? "General fitness"
        let pricePerMonth = intValue(from: data["pricePerMonth"]) ?? 0
        let rating = doubleValue(from: data["rating"]) ?? 5.0

        let availabilityRaw = data["availability"] as? String ?? CoachAvailability.online.rawValue
        let coachUserID = data["coachId"] as? String

        let photoFileName = data["photoFileName"] as? String
        let photoURL = data["photoURL"] as? String
        let clientCount = intValue(from: data["clientCount"]) ?? 0
        let reviewCount = intValue(from: data["reviewCount"]) ?? 0
        let isOnline = data["isOnline"] as? Bool ?? true
        let isVerified = data["isVerified"] as? Bool ?? true
        let location = data["location"] as? String ?? ""
        let specialties = data["specialties"] as? [String] ?? [specialty]
        let isLive = data["isLive"] as? Bool ?? true
        let isListed = data["isListed"] as? Bool ?? true
        let stripeChargesEnabled = data["stripeChargesEnabled"] as? Bool ?? false
        let availability = CoachAvailability(rawValue: availabilityRaw) ?? .online

        let profile = CoachProfile(
            id: id,
            name: name,
            specialty: specialty,
            pricePerMonth: pricePerMonth,
            isOnline: isOnline,
            rating: rating,
            bio: bio,
            clientCount: clientCount,
            reviewCount: reviewCount,
            isVerified: isVerified,
            availability: availability,
            location: location,
            specialties: specialties,
            photoFileName: photoFileName,
            photoURL: photoURL,
            isLive: isLive,
            isListed: isListed,
            coachUserID: coachUserID,
            stripeChargesEnabled: stripeChargesEnabled
        )
        return profile.sanitizedForDisplay()
    }

    private func decodeCoachClientConnection(from data: [String: Any], documentID: String) -> CoachClientConnection? {
        let clientUserID = (data["clientId"] as? String) ?? (data["clientUserID"] as? String)
        guard let clientUserID,
              let clientName = data["clientName"] as? String else { return nil }

        let coachFirestoreID = (data["coachId"] as? String) ?? (data["coachID"] as? String) ?? ""
        guard !coachFirestoreID.isEmpty else { return nil }

        let permissions = data["permissions"] as? [String: Any]
        // Default FALSE — matching security rules. A missing field must not look
        // like "sharing enabled" in the coach UI while rules deny the read.
        let shareWorkouts = permissions?["workouts"] as? Bool ?? data["shareWorkouts"] as? Bool ?? false
        let shareNutrition = permissions?["nutrition"] as? Bool ?? data["shareNutrition"] as? Bool ?? false
        let shareProgress = permissions?["progress"] as? Bool ?? data["shareProgress"] as? Bool ?? false

        let statusRaw = data["status"] as? String ?? CoachConnectionStatus.active.rawValue
        let status = CoachConnectionStatus(rawValue: statusRaw) ?? .active

        let coachUUID = UUID(uuidString: coachFirestoreID) ?? CoachAuthCrypto.stableCoachUUID(from: coachFirestoreID)
        let coachName = data["coachName"] as? String ?? "Coach"

        return CoachClientConnection(
            coachID: coachUUID,
            coachFirestoreID: coachFirestoreID,
            coachName: coachName,
            clientUserID: clientUserID,
            clientName: clientName,
            connectedAt: timestampDate(from: data["connectedAt"]) ?? .now,
            shareWorkouts: shareWorkouts,
            shareNutrition: shareNutrition,
            shareProgress: shareProgress,
            status: status,
            clientInitiatedContact: data["clientInitiatedContact"] as? Bool ?? false,
            documentID: documentID
        )
    }

    private func decodeCoachMessage(from data: [String: Any]) -> CoachMessage? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let conversationID = data["conversationID"] as? String,
              let senderRaw = data["senderRole"] as? String,
              let senderRole = CoachMessageSender(rawValue: senderRaw),
              let text = data["text"] as? String else { return nil }

        return CoachMessage(
            id: id,
            conversationID: conversationID,
            senderRole: senderRole,
            text: text,
            sentAt: timestampDate(from: data["sentAt"]) ?? .now
        )
    }

    // MARK: - Collections

    private func userDocument() throws -> DocumentReference {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        return db.collection("users").document(try userID())
    }

    private func weightsCollection() throws -> CollectionReference {
        try userDocument().collection("weights")
    }

    private func mealsCollection() throws -> CollectionReference {
        try userDocument().collection("meals")
    }

    private func workoutsCollection() throws -> CollectionReference {
        try userDocument().collection("workouts")
    }

    private func routinesCollection() throws -> CollectionReference {
        try userDocument().collection("routines")
    }

    private func userID() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreDatabaseError.notAuthenticated
        }
        return uid
    }

    // MARK: - Encoding

    private func weightPayload(_ entry: WeightEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "weight": entry.weight,
            "date": Timestamp(date: entry.date),
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private func mealPayload(_ entry: FoodEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "name": entry.name,
            "calories": entry.calories,
            "protein": entry.protein,
            "carbs": entry.carbs,
            "fat": entry.fat,
            "meal": entry.meal.rawValue,
            "date": Timestamp(date: entry.date),
            "servingLabel": entry.servingLabel,
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private func workoutPayload(_ entry: WorkoutEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "exerciseName": entry.exercise.name,
            "muscleGroup": entry.exercise.muscleGroup,
            "exerciseID": entry.exercise.id.uuidString,
            "date": Timestamp(date: entry.date),
            "notes": entry.notes,
            "sets": entry.sets.map { encodeSet($0) },
            // Planned template sets for scheduled Custom days (often empty logged sets).
            "plannedSets": entry.plannedSets.map { encodeSet($0) },
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private func encodeSet(_ set: WorkoutSet) -> [String: Any] {
        [
            "id": set.id.uuidString,
            "reps": set.reps,
            "weight": set.weight,
            "rpe": set.rpe as Any
        ]
    }

    private func routinePayload(_ routine: WorkoutRoutine) -> [String: Any] {
        [
            "id": routine.id.uuidString,
            "name": routine.name,
            "exercises": routine.sortedExercises.map { item -> [String: Any] in
                var payload: [String: Any] = [
                    "id": item.id.uuidString,
                    "exerciseID": item.exercise.id.uuidString,
                    "exerciseName": item.exercise.name,
                    "muscleGroup": item.exercise.muscleGroup,
                    "sortOrder": item.sortOrder,
                    "plannedSetCount": item.plannedSetCount,
                    "plannedReps": item.plannedReps
                ]
                if let weight = item.plannedWeight {
                    payload["plannedWeight"] = weight
                }
                return payload
            },
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private func decodeRoutine(from data: [String: Any]) -> WorkoutRoutine? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String else { return nil }

        let exercisesData = data["exercises"] as? [[String: Any]] ?? []
        let exercises = exercisesData.compactMap { item -> RoutineExerciseItem? in
            guard let itemIDString = item["id"] as? String,
                  let itemID = UUID(uuidString: itemIDString),
                  let exerciseName = item["exerciseName"] as? String,
                  let muscleGroup = item["muscleGroup"] as? String,
                  let sortOrder = intValue(from: item["sortOrder"]) else { return nil }

            let exerciseID = (item["exerciseID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let plannedSetCount = intValue(from: item["plannedSetCount"]) ?? 3
            let plannedReps = intValue(from: item["plannedReps"]) ?? 8
            let plannedWeight = doubleValue(from: item["plannedWeight"])

            return RoutineExerciseItem(
                id: itemID,
                exercise: Exercise(id: exerciseID, name: exerciseName, muscleGroup: muscleGroup),
                sortOrder: sortOrder,
                plannedSetCount: plannedSetCount,
                plannedReps: plannedReps,
                plannedWeight: plannedWeight
            )
        }

        return WorkoutRoutine(id: id, name: name, exercises: exercises)
    }

    // MARK: - Decoding

    private func decodeUserProfile(from data: [String: Any]) -> FirestoreUserProfile {
        let defaults = FirestoreUserProfile.empty
        return FirestoreUserProfile(
            hasCompletedOnboarding: data["hasCompletedOnboarding"] as? Bool ?? false,
            profileName: data["profileName"] as? String ?? "",
            goalRaw: data["goalRaw"] as? String ?? defaults.goalRaw,
            experienceRaw: data["experienceRaw"] as? String ?? defaults.experienceRaw,
            calorieTarget: intValue(from: data["calorieTarget"]) ?? defaults.calorieTarget,
            proteinTarget: intValue(from: data["proteinTarget"]) ?? defaults.proteinTarget,
            carbTarget: intValue(from: data["carbTarget"]) ?? defaults.carbTarget,
            fatTarget: intValue(from: data["fatTarget"]) ?? defaults.fatTarget,
            genderRaw: data["genderRaw"] as? String ?? defaults.genderRaw,
            birthday: timestampDate(from: data["birthday"]) ?? defaults.birthday,
            heightCm: doubleValue(from: data["heightCm"]) ?? defaults.heightCm,
            bodyWeightKg: doubleValue(from: data["bodyWeightKg"]) ?? defaults.bodyWeightKg,
            measurementSystemRaw: data["measurementSystemRaw"] as? String ?? defaults.measurementSystemRaw,
            activityLevelRaw: data["activityLevelRaw"] as? String ?? defaults.activityLevelRaw,
            hasCoach: data["hasCoach"] as? Bool ?? false,
            hasCompletedProgramSetup: data["hasCompletedProgramSetup"] as? Bool ?? false,
            workoutScheduleJSON: data["workoutScheduleJSON"] as? String ?? "",
            ownerUserID: data["ownerUserID"] as? String ?? "",
            isCoach: data["isCoach"] as? Bool ?? false,
            coachActivatedAt: timestampDate(from: data["coachActivatedAt"]),
            photoFileName: data["photoFileName"] as? String,
            photoURL: data["photoURL"] as? String
        )
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    private func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }

    private func decodeWeight(from data: [String: Any]) -> WeightEntry? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let weight = data["weight"] as? Double,
              let date = timestampDate(from: data["date"]) else { return nil }

        return WeightEntry(id: id, weight: weight, date: date)
    }

    private func decodeMeal(from data: [String: Any]) -> FoodEntry? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let calories = data["calories"] as? Int,
              let protein = data["protein"] as? Int,
              let carbs = data["carbs"] as? Int,
              let fat = data["fat"] as? Int,
              let mealRaw = data["meal"] as? String,
              let meal = MealType(rawValue: mealRaw),
              let date = timestampDate(from: data["date"]) else { return nil }

        return FoodEntry(
            id: id,
            name: name,
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            meal: meal,
            date: date,
            servingLabel: data["servingLabel"] as? String ?? ""
        )
    }

    private func decodeWorkout(from data: [String: Any]) -> WorkoutEntry? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let exerciseName = data["exerciseName"] as? String,
              let muscleGroup = data["muscleGroup"] as? String,
              let date = timestampDate(from: data["date"]) else { return nil }

        let exerciseID = (data["exerciseID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let notes = data["notes"] as? String ?? ""
        let setsData = data["sets"] as? [[String: Any]] ?? []
        let sets = setsData.compactMap { decodeSet(from: $0) }
        let plannedData = data["plannedSets"] as? [[String: Any]] ?? []
        let plannedSets = plannedData.compactMap { decodeSet(from: $0) }

        return WorkoutEntry(
            id: id,
            exercise: Exercise(id: exerciseID, name: exerciseName, muscleGroup: muscleGroup),
            sets: sets,
            plannedSets: plannedSets,
            date: date,
            notes: notes
        )
    }

    private func decodeSet(from data: [String: Any]) -> WorkoutSet? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString) else { return nil }
        // Firestore may store numbers as Int or Double depending on write path.
        guard let reps = intValue(from: data["reps"]),
              let weight = doubleValue(from: data["weight"]) else { return nil }

        return WorkoutSet(id: id, reps: reps, weight: weight, rpe: intValue(from: data["rpe"]))
    }

    private func timestampDate(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }
        if let date = value as? Date {
            return date
        }
        return nil
    }
}
