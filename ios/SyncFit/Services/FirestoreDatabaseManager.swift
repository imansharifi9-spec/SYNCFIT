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
        coachActivatedAt: nil
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
        try await userDocument().setData(data, merge: true)
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
        try await workoutsCollection()
            .document(entry.id.uuidString)
            .setData(workoutPayload(entry))
    }

    func fetchWorkouts() async throws -> [WorkoutEntry] {
        let snapshot = try await workoutsCollection()
            .order(by: "date", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { decodeWorkout(from: $0.data()) }
    }

    func deleteWorkout(_ entry: WorkoutEntry) async throws {
        try await workoutsCollection().document(entry.id.uuidString).delete()
    }

    func fetchAllUserData() async throws -> (weights: [WeightEntry], meals: [FoodEntry], workouts: [WorkoutEntry]) {
        async let weights = fetchWeights()
        async let meals = fetchMeals()
        async let workouts = fetchWorkouts()
        return try await (weights, meals, workouts)
    }

    // MARK: - Coaches marketplace

    func saveCoachProfile(_ profile: CoachProfile) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let coachDocumentID = profile.coachUserID ?? profile.id.uuidString
        let data: [String: Any] = [
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
        try await db.collection("coaches").document(coachDocumentID).setData(data, merge: true)
    }

    func fetchCoachProfiles() async throws -> [CoachProfile] {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let snapshot = try await db.collection("coaches")
            .whereField("isLive", isEqualTo: true)
            .getDocuments()
        return snapshot.documents.compactMap { decodeCoachProfile(from: $0.data()) }
            .filter(\.isListed)
    }

    func saveCoachClientConnection(_ connection: CoachClientConnection) async throws {
        guard let db else { throw FirestoreDatabaseError.firebaseUnavailable }
        let coachKey = connection.coachFirestoreID
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
        try await db.collection("coach_clients")
            .document(connection.documentID)
            .setData(data, merge: true)
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

    func observeClientWorkouts(
        clientUserID: String,
        onChange: @escaping ([WorkoutEntry]) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("users").document(clientUserID).collection("workouts")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, _ in
                let workouts = snapshot?.documents.compactMap { self.decodeWorkout(from: $0.data()) } ?? []
                onChange(workouts)
            }
    }

    func observeClientMeals(
        clientUserID: String,
        onChange: @escaping ([FoodEntry]) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("users").document(clientUserID).collection("meals")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, _ in
                let meals = snapshot?.documents.compactMap { self.decodeMeal(from: $0.data()) } ?? []
                onChange(meals)
            }
    }

    func observeClientWeights(
        clientUserID: String,
        onChange: @escaping ([WeightEntry]) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("users").document(clientUserID).collection("weights")
            .order(by: "date", descending: true)
            .addSnapshotListener { snapshot, _ in
                let weights = snapshot?.documents.compactMap { self.decodeWeight(from: $0.data()) } ?? []
                onChange(weights)
            }
    }

    func observeClientProfile(
        clientUserID: String,
        onChange: @escaping (FirestoreUserProfile) -> Void
    ) -> ListenerRegistration? {
        guard let db else { return nil }
        return db.collection("users").document(clientUserID)
            .addSnapshotListener { snapshot, _ in
                let profile = snapshot?.data().map { self.decodeUserProfile(from: $0) } ?? .empty
                onChange(profile)
            }
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
        var data: [String: Any] = [
            "id": message.id.uuidString,
            "conversationID": message.conversationID,
            "senderRole": message.senderRole.rawValue,
            "text": message.text,
            "sentAt": Timestamp(date: message.sentAt),
            "coachId": coachFirestoreID,
            "coachID": coachFirestoreID
        ]
        if let clientUserID {
            data["clientUserID"] = clientUserID
        }
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
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let name = data["name"] as? String,
              let specialty = data["specialty"] as? String,
              let pricePerMonth = data["pricePerMonth"] as? Int,
              let rating = data["rating"] as? Double,
              let bio = data["bio"] as? String else { return nil }

        let availabilityRaw = data["availability"] as? String ?? CoachAvailability.online.rawValue
        let coachUserID = data["coachId"] as? String

        let profile = CoachProfile(
            id: id,
            name: name,
            specialty: specialty,
            pricePerMonth: pricePerMonth,
            isOnline: data["isOnline"] as? Bool ?? true,
            rating: rating,
            bio: bio,
            clientCount: data["clientCount"] as? Int ?? 0,
            reviewCount: data["reviewCount"] as? Int ?? 0,
            isVerified: data["isVerified"] as? Bool ?? true,
            availability: CoachAvailability(rawValue: availabilityRaw) ?? .online,
            location: data["location"] as? String ?? "",
            specialties: data["specialties"] as? [String] ?? [specialty],
            isLive: data["isLive"] as? Bool ?? true,
            isListed: data["isListed"] as? Bool ?? true,
            coachUserID: coachUserID
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
        let shareWorkouts = permissions?["workouts"] as? Bool ?? data["shareWorkouts"] as? Bool ?? true
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
            clientInitiatedContact: data["clientInitiatedContact"] as? Bool ?? false
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
            "sets": entry.sets.map { set in
                [
                    "id": set.id.uuidString,
                    "reps": set.reps,
                    "weight": set.weight,
                    "rpe": set.rpe as Any
                ]
            },
            "updatedAt": FieldValue.serverTimestamp()
        ]
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
            coachActivatedAt: timestampDate(from: data["coachActivatedAt"])
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

        return WorkoutEntry(
            id: id,
            exercise: Exercise(id: exerciseID, name: exerciseName, muscleGroup: muscleGroup),
            sets: sets,
            date: date,
            notes: notes
        )
    }

    private func decodeSet(from data: [String: Any]) -> WorkoutSet? {
        guard let idString = data["id"] as? String,
              let id = UUID(uuidString: idString),
              let reps = data["reps"] as? Int,
              let weight = data["weight"] as? Double else { return nil }

        return WorkoutSet(id: id, reps: reps, weight: weight, rpe: data["rpe"] as? Int)
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
