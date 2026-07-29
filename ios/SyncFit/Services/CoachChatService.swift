import Foundation
import FirebaseAuth
import FirebaseFirestore

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let senderId: String
    let text: String
    let timestamp: Date
    let routineCard: RoutineCardPayload?

    init(
        id: String,
        senderId: String,
        text: String,
        timestamp: Date,
        routineCard: RoutineCardPayload? = nil
    ) {
        self.id = id
        self.senderId = senderId
        self.text = text
        self.timestamp = timestamp
        self.routineCard = routineCard
    }

    var normalizedSenderId: String {
        senderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRoutineCard: Bool {
        routineCard != nil
    }
}

struct ChatConversation: Identifiable, Hashable {
    let id: String
    let coachId: String
    let userId: String
    let coachName: String
    let userName: String
    var lastMessage: String
    var lastMessageAt: Date
    var lastMessageSenderId: String
    /// True when the latest inbound message for `viewerId` is still unread.
    var hasUnreadForViewer: Bool

    func isUnread(for viewerId: String) -> Bool {
        hasUnreadForViewer
            && !lastMessageSenderId.isEmpty
            && lastMessageSenderId != viewerId
    }
}

struct UnreadCoachConversation: Identifiable, Hashable {
    let conversationId: String
    let coachId: String
    let coachName: String
    let coachSpecialty: String
    let userId: String
    let userName: String
    let preview: String
    let timestamp: Date

    var id: String { conversationId }
}

struct HomeNotificationItem: Identifiable {
    enum Kind {
        case coachMessage
        case personalRecord
        case streak
    }

    let id: String
    let kind: Kind
    let title: String
    let preview: String
    let timestamp: Date
    let chatRoute: CoachChatRoute?
}

@MainActor
final class CoachChatService: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var conversations: [ChatConversation] = []
    @Published private(set) var unreadCoachConversations: [UnreadCoachConversation] = []

    /// True when the signed-in user has at least one unread inbound chat message
    /// (client ← coach, or coach ← client).
    var hasUnreadCoachMessages: Bool {
        !unreadCoachConversations.isEmpty
    }

    var hasUnreadMessages: Bool { hasUnreadCoachMessages }

    private var messagesListener: ListenerRegistration?
    private var conversationsListener: ListenerRegistration?
    private var unreadMonitorParticipantId: String?

    /// Bumps on every messages start/stop so overlapping shell→attach Tasks cannot
    /// write after teardown (same pattern as `CoachClientDataViewModel`).
    private var messagesObservationGeneration = 0
    /// Bumps on every conversations start/stop for the same reason.
    private var conversationsObservationGeneration = 0

    var isAvailable: Bool {
        FirebaseConfiguration.isConfigured
    }

    private var db: Firestore? {
        guard FirebaseConfiguration.isConfigured else { return nil }
        return Firestore.firestore()
    }

    static func conversationId(userId: String, coachId: String) -> String {
        [userId, coachId].sorted().joined(separator: "_")
    }

    /// Stable participant list matching Firestore rules + conversation doc id.
    private static func participants(userId: String, coachId: String) -> [String] {
        [userId, coachId].sorted()
    }

    /// Rejects empty IDs and Swift `UUID.uuidString` placeholders (hyphenated).
    /// Firebase Auth UIDs never contain `-`; portal `id.uuidString` always does.
    static func isValidConversationParticipantId(_ participantId: String) -> Bool {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if Self.looksLikePlaceholderUUID(trimmed) { return false }
        return true
    }

    private static func looksLikePlaceholderUUID(_ value: String) -> Bool {
        // 8-4-4-4-12 hex with hyphens — matches `UUID.uuidString`, not Firebase Auth UIDs.
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    func startObservingMessages(conversationId: String, coachId: String, userId: String) {
        beginNewMessagesObservationSession()
        let generation = messagesObservationGeneration
        guard db != nil else {
            print("[ChatSync] Listen skipped — Firestore unavailable gen=\(generation)")
            return
        }

        // Message list rules require the parent conversation doc to exist so
        // participants can be resolved. Create a shell before attaching the listener.
        Task {
            await ensureConversationShell(
                conversationId: conversationId,
                coachId: coachId,
                userId: userId
            )
            await MainActor.run {
                guard self.messagesObservationGeneration == generation else {
                    print(
                        "[ChatSync] Stale messages attach discarded gen=\(generation) " +
                        "current=\(self.messagesObservationGeneration) conversation=\(conversationId)"
                    )
                    return
                }
                self.attachMessagesListener(
                    conversationId: conversationId,
                    coachId: coachId,
                    userId: userId,
                    generation: generation
                )
            }
        }
    }

    private func beginNewMessagesObservationSession() {
        messagesObservationGeneration += 1
        removeMessagesListener()
        messages = []
        print("[ChatSync] Messages session gen=\(messagesObservationGeneration)")
    }

    private func removeMessagesListener() {
        messagesListener?.remove()
        messagesListener = nil
    }

    private func attachMessagesListener(
        conversationId: String,
        coachId: String,
        userId: String,
        generation: Int
    ) {
        guard let db else { return }
        print("[ChatSync] Listening conversations/\(conversationId)/messages gen=\(generation)")
        messagesListener = db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("[ChatSync] Listen FAILED conversations/\(conversationId)/messages: \(error)")
                    return
                }
                let parsed = Self.parseMessages(
                    from: snapshot?.documents ?? [],
                    coachId: coachId,
                    userId: userId
                )
                print("[ChatSync] Listen OK count=\(parsed.count) conversation=\(conversationId) gen=\(generation)")
                Task { @MainActor in
                    guard self.messagesObservationGeneration == generation else {
                        print(
                            "[ChatSync] Stale messages snapshot discarded gen=\(generation) " +
                            "current=\(self.messagesObservationGeneration)"
                        )
                        return
                    }
                    self.messages = parsed
                }
                Task {
                    await self.repairInappropriateMessagesIfNeeded(
                        conversationId: conversationId,
                        documents: snapshot?.documents ?? []
                    )
                }
            }
    }

    /// Ensures conversations/{id} exists so message subcollection rules can resolve participants.
    @discardableResult
    private func ensureConversationShell(
        conversationId: String,
        coachId: String,
        userId: String,
        coachName: String = "",
        userName: String = ""
    ) async -> Bool {
        guard let db else {
            print("[ChatSync] PART1 FAILED — Firestore unavailable")
            return false
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            print("[ChatSync] PART1 FAILED — not authenticated")
            return false
        }
        guard uid == userId || uid == coachId else {
            print("[ChatSync] PART1 FAILED — auth \(uid) not in [\(userId), \(coachId)]")
            return false
        }
        let expectedId = Self.conversationId(userId: userId, coachId: coachId)
        guard conversationId == expectedId else {
            print("[ChatSync] PART1 FAILED — id mismatch got=\(conversationId) expected=\(expectedId)")
            return false
        }

        let ref = db.collection("conversations").document(conversationId)
        let people = Self.participants(userId: userId, coachId: coachId)
        var data: [String: Any] = [
            "participants": people,
            "coachId": coachId,
            "userId": userId,
            "createdAt": FieldValue.serverTimestamp()
        ]
        if !coachName.isEmpty { data["coachName"] = coachName }
        if !userName.isEmpty { data["userName"] = userName }

        let authMatchesUser = uid == userId
        let authMatchesCoach = uid == coachId
        print("[ChatSync] PART1 write conversations/\(conversationId)")
        print("[ChatSync] PART1 auth=\(uid) userId=\(userId) coachId=\(coachId) auth==user=\(authMatchesUser) auth==coach=\(authMatchesCoach) participants=\(people)")
        do {
            // merge:true maps to create (missing) or update (exists). Rules allow both
            // when auth.uid is in participants.
            try await ref.setData(data, merge: true)
            print("[ChatSync] PART1 OK conversations/\(conversationId)")
            return true
        } catch {
            print("[ChatSync] PART1 FAILED conversations/\(conversationId): \(error)")
            return false
        }
    }

    func stopObservingMessages() {
        messagesObservationGeneration += 1
        removeMessagesListener()
        messages = []
        print("[ChatSync] stopObservingMessages gen=\(messagesObservationGeneration)")
    }

    // MARK: - Test seams (generation / participant guards)

    /// Current messages observation generation (unit tests).
    var messagesObservationGenerationForTesting: Int { messagesObservationGeneration }

    /// Current conversations observation generation (unit tests).
    var conversationsObservationGenerationForTesting: Int { conversationsObservationGeneration }

    /// Participant currently bound to the conversations listener, if any (unit tests).
    var unreadMonitorParticipantIdForTesting: String? { unreadMonitorParticipantId }

    /// Simulates a late snapshot apply from a superseded attach Task (unit tests).
    func applyMessagesSnapshotForTesting(_ parsed: [ChatMessage], generation: Int) {
        guard messagesObservationGeneration == generation else { return }
        messages = parsed
    }

    /// Simulates a late conversations snapshot apply from a superseded session (unit tests).
    func applyConversationsSnapshotForTesting(
        _ parsed: [ChatConversation],
        generation: Int
    ) {
        guard conversationsObservationGeneration == generation else { return }
        conversations = parsed
    }

    /// Starts a messages session without Firestore (unit tests) and returns its generation.
    @discardableResult
    func beginMessagesObservationSessionForTesting() -> Int {
        beginNewMessagesObservationSession()
        return messagesObservationGeneration
    }

    /// Starts a conversations session without Firestore (unit tests) and returns its generation.
    @discardableResult
    func beginConversationsObservationSessionForTesting(participantId: String) -> Int? {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidConversationParticipantId(trimmed) else { return nil }
        beginNewConversationsObservationSession()
        unreadMonitorParticipantId = trimmed
        return conversationsObservationGeneration
    }

    func sendMessage(
        conversationId: String,
        senderId: String,
        text: String,
        coachId: String,
        coachName: String,
        userId: String,
        userName: String
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db else {
            print("[ChatSync] Send skipped — empty text or Firestore unavailable")
            return false
        }

        guard let uid = Auth.auth().currentUser?.uid else {
            print("[ChatSync] Send FAILED: missing authenticated senderId")
            return false
        }
        let resolvedSenderId = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedSenderId.isEmpty else {
            print("[ChatSync] Send FAILED: empty authenticated senderId")
            return false
        }
        guard resolvedSenderId == userId || resolvedSenderId == coachId else {
            print("[ChatSync] Send FAILED: auth \(resolvedSenderId) not a participant of user=\(userId) coach=\(coachId)")
            return false
        }

        let expectedId = Self.conversationId(userId: userId, coachId: coachId)
        print("[ChatSync] Send start conversation=\(conversationId) expected=\(expectedId) sender=\(resolvedSenderId) userId=\(userId) coachId=\(coachId)")

        // Sequential writes (not one batch) so PART1 vs PART2 failures are distinct,
        // and message create can resolve participants via get() after PART1 commits.
        let shellOK = await ensureConversationShell(
            conversationId: conversationId,
            coachId: coachId,
            userId: userId,
            coachName: coachName,
            userName: userName
        )
        guard shellOK else {
            print("[ChatSync] Send aborted — PART1 conversation write denied")
            return false
        }

        let conversationRef = db.collection("conversations").document(conversationId)
        let messageRef = conversationRef.collection("messages").document()
        let people = Self.participants(userId: userId, coachId: coachId)

        do {
            try await conversationRef.setData([
                "participants": people,
                "lastMessage": trimmed,
                "lastMessageAt": FieldValue.serverTimestamp(),
                "lastMessageSenderId": resolvedSenderId,
                "coachId": coachId,
                "coachName": coachName,
                "userId": userId,
                "userName": userName
            ], merge: true)
            print("[ChatSync] PART1 metadata update OK conversations/\(conversationId)")
        } catch {
            print("[ChatSync] PART1 metadata update FAILED conversations/\(conversationId): \(error)")
            return false
        }

        let messagePayload: [String: Any] = [
            "senderId": resolvedSenderId,
            "text": trimmed,
            "timestamp": FieldValue.serverTimestamp(),
            "isRead": false
        ]
        let parts = conversationId.split(separator: "_").map(String.init)
        let uidInPath = parts.contains(resolvedSenderId)
        print("[ChatSync] PART2 write conversations/\(conversationId)/messages/\(messageRef.documentID)")
        print("[ChatSync] PART2 senderId=\(resolvedSenderId) pathParts=\(parts) uidInPath=\(uidInPath)")
        do {
            try await messageRef.setData(messagePayload)
            print("[ChatSync] PART2 Send OK messageId=\(messageRef.documentID) conversation=\(conversationId)")
            return true
        } catch {
            print("[ChatSync] PART2 Send FAILED conversations/\(conversationId)/messages/\(messageRef.documentID): \(error)")
            return false
        }
    }

    func sendRoutineCard(
        conversationId: String,
        coachId: String,
        coachName: String,
        userId: String,
        userName: String,
        template: CoachRoutineTemplate,
        coachNote: String?
    ) async -> Bool {
        guard let db else { return false }

        guard let uid = Auth.auth().currentUser?.uid else {
            print("Routine send failed: missing authenticated senderId")
            return false
        }
        let resolvedSenderId = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedSenderId.isEmpty else { return false }

        let trimmedNote = coachNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (trimmedNote?.isEmpty == false) ? trimmedNote : nil
        let payload = RoutineCardPayload(template: template, coachNote: note, implementedAt: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payloadData = try? encoder.encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            print("Routine send failed: could not encode payload")
            return false
        }

        let preview = template.chatPreviewText
        print("[ChatSync] Routine card send conversation=\(conversationId) sender=\(resolvedSenderId)")
        let shellOK = await ensureConversationShell(
            conversationId: conversationId,
            coachId: coachId,
            userId: userId,
            coachName: coachName,
            userName: userName
        )
        guard shellOK else { return false }

        let conversationRef = db.collection("conversations").document(conversationId)
        let messageRef = conversationRef.collection("messages").document()
        let people = Self.participants(userId: userId, coachId: coachId)

        do {
            try await conversationRef.setData([
                "participants": people,
                "lastMessage": preview,
                "lastMessageAt": FieldValue.serverTimestamp(),
                "lastMessageSenderId": resolvedSenderId,
                "coachId": coachId,
                "coachName": coachName,
                "userId": userId,
                "userName": userName
            ], merge: true)
            try await messageRef.setData([
                "senderId": resolvedSenderId,
                "text": preview,
                "messageType": "routineCard",
                "routineCardJSON": payloadJSON,
                "timestamp": FieldValue.serverTimestamp(),
                "isRead": false
            ])
            print("[ChatSync] Routine card Send OK messageId=\(messageRef.documentID)")
            return true
        } catch {
            print("[ChatSync] Routine card Send FAILED: \(error)")
            return false
        }
    }

    func markRoutineImplemented(
        conversationId: String,
        messageId: String,
        payload: RoutineCardPayload
    ) async -> Bool {
        guard let db else { return false }

        var updated = payload
        updated.implementedAt = .now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payloadData = try? encoder.encode(updated),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return false
        }

        do {
            try await db.collection("conversations")
                .document(conversationId)
                .collection("messages")
                .document(messageId)
                .updateData(["routineCardJSON": payloadJSON])
            return true
        } catch {
            print("Mark routine implemented failed: \(error)")
            return false
        }
    }

    /// Keeps conversation list + unread badges live for the signed-in participant
    /// (client or coach). Safe to call repeatedly; restarts only when the UID changes.
    /// Never accepts a placeholder `UUID.uuidString` — that would wipe a good listener.
    func startUnreadMonitoring(for participantId: String) {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidConversationParticipantId(trimmed) else {
            let line =
                "[ChatSync] Unread monitor SKIP — rejected participant id " +
                "(empty or placeholder UUID): \(participantId)"
            print(line)
            Self.appendProbeLog(line)
            return
        }
        guard let db else {
            Self.appendProbeLog("[ChatSync] Unread monitor SKIP — Firestore unavailable")
            return
        }
        if unreadMonitorParticipantId == trimmed, conversationsListener != nil {
            Self.appendProbeLog(
                "[ChatSync] Unread monitor already attached participant=\(trimmed) " +
                "conversations=\(conversations.count)"
            )
            return
        }

        beginNewConversationsObservationSession()
        let generation = conversationsObservationGeneration
        unreadMonitorParticipantId = trimmed
        let startLine = "[ChatSync] Unread monitor start participant=\(trimmed) gen=\(generation)"
        print(startLine)
        Self.appendProbeLog(startLine)

        conversationsListener = db.collection("conversations")
            .whereField("participants", arrayContains: trimmed)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    let errLine = "[ChatSync] Unread monitor FAILED: \(error)"
                    print(errLine)
                    Self.appendProbeLog(errLine)
                    // Keep last good conversations — do not wipe on stream errors.
                    return
                }
                let documents = snapshot?.documents ?? []
                let fromCache = snapshot?.metadata.isFromCache == true
                Self.appendProbeLog(
                    "[ChatSync] Unread monitor snapshot docs=\(documents.count) " +
                    "participant=\(trimmed) gen=\(generation) cache=\(fromCache)"
                )
                Task {
                    await self.applyConversationsDocuments(
                        documents,
                        viewerId: trimmed,
                        generation: generation
                    )
                }
            }

        // Incomplete local shells (coachId/userId only) used to parse to [] and stick.
        // Always hydrate once from the server after attach.
        Task {
            do {
                let serverSnap = try await db.collection("conversations")
                    .whereField("participants", arrayContains: trimmed)
                    .getDocuments(source: .server)
                Self.appendProbeLog(
                    "[ChatSync] Unread monitor server hydrate docs=\(serverSnap.documents.count) " +
                    "gen=\(generation)"
                )
                await self.applyConversationsDocuments(
                    serverSnap.documents,
                    viewerId: trimmed,
                    generation: generation
                )
            } catch {
                Self.appendProbeLog("[ChatSync] Unread monitor server hydrate FAILED: \(error)")
            }
        }
    }

    private func applyConversationsDocuments(
        _ documents: [QueryDocumentSnapshot],
        viewerId: String,
        generation: Int
    ) async {
        let parsed = await parseConversationsWithUnread(
            from: documents,
            viewerId: viewerId
        )
        await MainActor.run {
            guard conversationsObservationGeneration == generation else {
                print(
                    "[ChatSync] Stale conversations snapshot discarded gen=\(generation) " +
                    "current=\(conversationsObservationGeneration)"
                )
                return
            }
            // Never replace a populated list with an empty parse from a cache shell.
            if parsed.isEmpty, !conversations.isEmpty {
                Self.appendProbeLog(
                    "[ChatSync] Ignoring empty conversations overwrite " +
                    "(keeping \(conversations.count)) gen=\(generation)"
                )
                return
            }
            conversations = parsed
            unreadCoachConversations = parsed
                .filter { $0.isUnread(for: viewerId) }
                .map { conversation in
                    UnreadCoachConversation(
                        conversationId: conversation.id,
                        coachId: conversation.coachId,
                        coachName: conversation.coachName,
                        coachSpecialty: "",
                        userId: conversation.userId,
                        userName: conversation.userName,
                        preview: conversation.lastMessage,
                        timestamp: conversation.lastMessageAt
                    )
                }
                .sorted { $0.timestamp > $1.timestamp }
            Self.appendProbeLog(
                "[ChatSync] Unread monitor applied count=\(parsed.count) gen=\(generation)"
            )
        }
        await repairInappropriateConversationsIfNeeded(from: documents)
    }

    func observeConversations(forParticipant participantId: String) {
        startUnreadMonitoring(for: participantId)
    }

    private func beginNewConversationsObservationSession() {
        conversationsObservationGeneration += 1
        removeConversationsListener()
        unreadMonitorParticipantId = nil
        conversations = []
        print("[ChatSync] Conversations session gen=\(conversationsObservationGeneration)")
    }

    private func removeConversationsListener() {
        conversationsListener?.remove()
        conversationsListener = nil
    }

    func stopObservingConversations() {
        conversationsObservationGeneration += 1
        removeConversationsListener()
        unreadMonitorParticipantId = nil
        conversations = []
        print("[ChatSync] stopObservingConversations gen=\(conversationsObservationGeneration)")
    }

    func teardown() {
        stopObservingMessages()
        stopObservingConversations()
        unreadCoachConversations = []
    }

    func refreshUnreadForClient(userId: String) async {
        await refreshUnreadForParticipant(userId)
    }

    /// Recompute unread badges for the signed-in participant (client or coach).
    func refreshUnreadForParticipant(_ participantId: String) async {
        let trimmed = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db else {
            unreadCoachConversations = []
            return
        }

        do {
            let snapshot = try await db.collection("conversations")
                .whereField("participants", arrayContains: trimmed)
                .getDocuments()
            let parsed = await parseConversationsWithUnread(
                from: snapshot.documents,
                viewerId: trimmed
            )
            conversations = parsed
            unreadCoachConversations = parsed
                .filter { $0.isUnread(for: trimmed) }
                .map { conversation in
                    UnreadCoachConversation(
                        conversationId: conversation.id,
                        coachId: conversation.coachId,
                        coachName: conversation.coachName,
                        coachSpecialty: "",
                        userId: conversation.userId,
                        userName: conversation.userName,
                        preview: conversation.lastMessage,
                        timestamp: conversation.lastMessageAt
                    )
                }
                .sorted { $0.timestamp > $1.timestamp }
        } catch {
            print("[ChatSync] Unread refresh FAILED: \(error)")
        }
    }

    /// Whether the client has an unread message from this coach (My Coach card).
    func hasUnreadMessage(fromCoachId coachId: String) -> Bool {
        unreadCoachConversations.contains { $0.coachId == coachId }
    }

    /// Whether the coach has an unread message from this client.
    func hasUnreadMessage(fromClientId clientId: String) -> Bool {
        unreadCoachConversations.contains { $0.userId == clientId }
    }

    func markConversationRead(conversationId: String, currentUserId: String) async {
        guard let db else { return }
        let trimmedUserId = currentUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserId.isEmpty else { return }

        // Optimistically clear local badge for this thread immediately.
        unreadCoachConversations.removeAll { $0.conversationId == conversationId }
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].hasUnreadForViewer = false
        }

        do {
            let conversationRef = db.collection("conversations").document(conversationId)
            let snapshot = try await conversationRef
                .collection("messages")
                .order(by: "timestamp", descending: true)
                .limit(to: 50)
                .getDocuments()

            let batch = db.batch()
            var updated = false
            for document in snapshot.documents {
                let data = document.data()
                let senderId = (data["senderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isRead = data["isRead"] as? Bool ?? false
                guard senderId != trimmedUserId, !isRead else { continue }
                batch.updateData(["isRead": true], forDocument: document.reference)
                updated = true
            }

            if updated {
                try await batch.commit()
            }

            await refreshUnreadForParticipant(trimmedUserId)
        } catch {
            print("[ChatSync] Mark read FAILED: \(error)")
        }
    }

    private static func parseMessages(
        from documents: [QueryDocumentSnapshot],
        coachId: String,
        userId: String
    ) -> [ChatMessage] {
        documents.compactMap { document -> ChatMessage? in
            let data = document.data()
            guard let senderId = resolveSenderId(from: data, coachId: coachId, userId: userId) else {
                return nil
            }

            let messageType = data["messageType"] as? String ?? "text"
            var routineCard: RoutineCardPayload?
            if messageType == "routineCard",
               let json = data["routineCardJSON"] as? String,
               let jsonData = json.data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                routineCard = try? decoder.decode(RoutineCardPayload.self, from: jsonData)
            }

            let rawText = data["text"] as? String
            let text: String
            if let routineCard {
                text = routineCard.template.chatPreviewText
            } else if let rawText {
                text = CoachPlaceholderContent.sanitizedMessage(rawText)
            } else {
                return nil
            }

            let timestamp = (data["timestamp"] as? Timestamp)?.dateValue() ?? .distantPast
            return ChatMessage(
                id: document.documentID,
                senderId: senderId,
                text: text,
                timestamp: timestamp,
                routineCard: routineCard
            )
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    private static func resolveSenderId(
        from data: [String: Any],
        coachId: String,
        userId: String
    ) -> String? {
        if let raw = data["senderId"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let role = data["senderRole"] as? String {
            switch role.lowercased() {
            case "coach":
                let trimmedCoachId = coachId.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedCoachId.isEmpty ? nil : trimmedCoachId
            case "client":
                let trimmedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedUserId.isEmpty ? nil : trimmedUserId
            default:
                break
            }
        }

        return nil
    }

    private func parseConversationsWithUnread(
        from documents: [QueryDocumentSnapshot],
        viewerId: String
    ) async -> [ChatConversation] {
        var results: [ChatConversation] = []
        for document in documents {
            let data = document.data()
            guard let coachId = data["coachId"] as? String,
                  let userId = data["userId"] as? String,
                  !coachId.isEmpty,
                  !userId.isEmpty else {
                let keys = Array(data.keys).sorted().joined(separator: ",")
                print(
                    "[ChatSync] Skip conversation \(document.documentID) — missing coachId/userId keys=\(keys)"
                )
                Self.appendProbeLog(
                    "[ChatSync] Skip conversation \(document.documentID) — missing coachId/userId keys=\(keys)"
                )
                continue
            }

            // Names are display-only; never drop a thread because a shell write omitted them.
            let coachName = (data["coachName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let userName = (data["userName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedCoachName = (coachName?.isEmpty == false) ? coachName! : "Coach"
            let resolvedUserName = (userName?.isEmpty == false) ? userName! : "Client"

            let lastSender = (data["lastMessageSenderId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lastMessageAt = (data["lastMessageAt"] as? Timestamp)?.dateValue() ?? .distantPast
            let lastMessage = CoachPlaceholderContent.sanitizedMessage(
                data["lastMessage"] as? String ?? ""
            )

            // Probe when the latest sender is the other party, or when sender is
            // missing (legacy conversation docs written before lastMessageSenderId).
            var hasUnread = false
            if lastSender.isEmpty || lastSender != viewerId {
                hasUnread = await conversationHasUnreadInboundMessage(
                    document: document,
                    viewerId: viewerId
                )
            }

            results.append(
                ChatConversation(
                    id: document.documentID,
                    coachId: coachId,
                    userId: userId,
                    coachName: resolvedCoachName,
                    userName: resolvedUserName,
                    lastMessage: lastMessage,
                    lastMessageAt: lastMessageAt,
                    lastMessageSenderId: lastSender,
                    hasUnreadForViewer: hasUnread
                )
            )
            Self.appendProbeLog(
                "[ChatSync] Parsed conversation id=\(document.documentID) " +
                "user=\(resolvedUserName) last=\(lastMessage.prefix(40))"
            )
        }
        return results.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    private func conversationHasUnreadInboundMessage(
        document: QueryDocumentSnapshot,
        viewerId: String
    ) async -> Bool {
        do {
            let messagesSnapshot = try await document.reference
                .collection("messages")
                .order(by: "timestamp", descending: true)
                .limit(to: 12)
                .getDocuments()
            return messagesSnapshot.documents.contains { messageDoc in
                let messageData = messageDoc.data()
                let senderId = (messageData["senderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isRead = messageData["isRead"] as? Bool ?? false
                return senderId != viewerId && !senderId.isEmpty && !isRead
            }
        } catch {
            print("[ChatSync] Unread probe FAILED \(document.documentID): \(error)")
            return false
        }
    }

    private func repairInappropriateConversationsIfNeeded(from documents: [QueryDocumentSnapshot]) async {
        guard let db else { return }

        for document in documents {
            let lastMessage = document.data()["lastMessage"] as? String ?? ""
            guard CoachPlaceholderContent.isInappropriateMessage(lastMessage) else { continue }

            let sanitized = CoachPlaceholderContent.sanitizedMessage(lastMessage)
            try? await db.collection("conversations")
                .document(document.documentID)
                .updateData(["lastMessage": sanitized])
        }
    }

    private func repairInappropriateMessagesIfNeeded(
        conversationId: String,
        documents: [QueryDocumentSnapshot]
    ) async {
        guard let db else { return }

        for document in documents {
            let text = document.data()["text"] as? String ?? ""
            guard CoachPlaceholderContent.isInappropriateMessage(text) else { continue }

            let sanitized = CoachPlaceholderContent.sanitizedMessage(text)
            try? await db.collection("conversations")
                .document(conversationId)
                .collection("messages")
                .document(document.documentID)
                .updateData(["text": sanitized])
        }

        if let lastDocument = documents.last {
            let lastText = lastDocument.data()["text"] as? String ?? ""
            if CoachPlaceholderContent.isInappropriateMessage(lastText) {
                let sanitized = CoachPlaceholderContent.sanitizedMessage(lastText)
                try? await db.collection("conversations")
                    .document(conversationId)
                    .updateData(["lastMessage": sanitized])
            }
        }
    }

    private static func appendProbeLog(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        let url = URL(fileURLWithPath: "/tmp/syncfit-chatsync-probe.log")
        guard let data = stamped.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
