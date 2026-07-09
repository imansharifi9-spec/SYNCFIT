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

    var hasUnreadCoachMessages: Bool {
        !unreadCoachConversations.isEmpty
    }

    private var messagesListener: ListenerRegistration?
    private var conversationsListener: ListenerRegistration?

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

    func startObservingMessages(conversationId: String, coachId: String, userId: String) {
        stopObservingMessages()
        guard let db else { return }

        messagesListener = db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .order(by: "timestamp")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("Listen error: \(error)")
                    return
                }
                let parsed = Self.parseMessages(
                    from: snapshot?.documents ?? [],
                    coachId: coachId,
                    userId: userId
                )
                Task { @MainActor in
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

    func stopObservingMessages() {
        messagesListener?.remove()
        messagesListener = nil
        messages = []
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
        guard !trimmed.isEmpty, let db else { return false }

        guard let uid = Auth.auth().currentUser?.uid else {
            print("Send failed: missing authenticated senderId")
            return false
        }
        let resolvedSenderId = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedSenderId.isEmpty else {
            print("Send failed: empty authenticated senderId")
            return false
        }

        let conversationRef = db.collection("conversations").document(conversationId)
        let messageRef = conversationRef.collection("messages").document()
        let batch = db.batch()

        batch.setData([
            "participants": [userId, coachId],
            "lastMessage": trimmed,
            "lastMessageAt": FieldValue.serverTimestamp(),
            "lastMessageSenderId": resolvedSenderId,
            "coachId": coachId,
            "coachName": coachName,
            "userId": userId,
            "userName": userName,
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: conversationRef, merge: true)

        batch.setData([
            "senderId": resolvedSenderId,
            "text": trimmed,
            "timestamp": FieldValue.serverTimestamp(),
            "isRead": false
        ], forDocument: messageRef)

        do {
            try await batch.commit()
            return true
        } catch {
            print("Send failed: \(error)")
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
        let conversationRef = db.collection("conversations").document(conversationId)
        let messageRef = conversationRef.collection("messages").document()
        let batch = db.batch()

        batch.setData([
            "participants": [userId, coachId],
            "lastMessage": preview,
            "lastMessageAt": FieldValue.serverTimestamp(),
            "lastMessageSenderId": resolvedSenderId,
            "coachId": coachId,
            "coachName": coachName,
            "userId": userId,
            "userName": userName,
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: conversationRef, merge: true)

        batch.setData([
            "senderId": resolvedSenderId,
            "text": preview,
            "messageType": "routineCard",
            "routineCardJSON": payloadJSON,
            "timestamp": FieldValue.serverTimestamp(),
            "isRead": false
        ], forDocument: messageRef)

        do {
            try await batch.commit()
            return true
        } catch {
            print("Routine send failed: \(error)")
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

    func observeConversations(forParticipant participantId: String) {
        stopObservingConversations()
        guard let db else { return }

        conversationsListener = db.collection("conversations")
            .whereField("participants", arrayContains: participantId)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("Chat conversations listener error: \(error)")
                    return
                }
                let parsed = Self.parseConversations(from: snapshot?.documents ?? [])
                Task { @MainActor in
                    self.conversations = parsed
                }
                Task {
                    await self.repairInappropriateConversationsIfNeeded(from: snapshot?.documents ?? [])
                }
            }
    }

    func stopObservingConversations() {
        conversationsListener?.remove()
        conversationsListener = nil
        conversations = []
    }

    func teardown() {
        stopObservingMessages()
        stopObservingConversations()
        unreadCoachConversations = []
    }

    func refreshUnreadForClient(userId: String) async {
        guard let db else {
            unreadCoachConversations = []
            return
        }

        let trimmedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserId.isEmpty else {
            unreadCoachConversations = []
            return
        }

        do {
            let snapshot = try await db.collection("conversations")
                .whereField("participants", arrayContains: trimmedUserId)
                .getDocuments()

            var unread: [UnreadCoachConversation] = []

            for document in snapshot.documents {
                let data = document.data()
                guard let coachId = data["coachId"] as? String,
                      let coachName = data["coachName"] as? String,
                      let clientUserId = data["userId"] as? String,
                      let userName = data["userName"] as? String else { continue }

                let lastSender = (data["lastMessageSenderId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !lastSender.isEmpty, lastSender != trimmedUserId else { continue }

                let messagesSnapshot = try await document.reference
                    .collection("messages")
                    .order(by: "timestamp", descending: true)
                    .limit(to: 12)
                    .getDocuments()

                guard let unreadMessage = messagesSnapshot.documents.first(where: { messageDoc in
                    let messageData = messageDoc.data()
                    let senderId = (messageData["senderId"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let isRead = messageData["isRead"] as? Bool ?? false
                    return senderId != trimmedUserId && !isRead
                }) else { continue }

                let messageData = unreadMessage.data()
                let preview = CoachPlaceholderContent.sanitizedMessage(
                    messageData["text"] as? String ?? ""
                )
                let timestamp = (messageData["timestamp"] as? Timestamp)?.dateValue()
                    ?? (data["lastMessageAt"] as? Timestamp)?.dateValue()
                    ?? .distantPast

                unread.append(
                    UnreadCoachConversation(
                        conversationId: document.documentID,
                        coachId: coachId,
                        coachName: coachName,
                        coachSpecialty: "",
                        userId: clientUserId,
                        userName: userName,
                        preview: preview,
                        timestamp: timestamp
                    )
                )
            }

            unreadCoachConversations = unread.sorted { $0.timestamp > $1.timestamp }
        } catch {
            print("Unread refresh failed: \(error)")
        }
    }

    func markConversationRead(conversationId: String, currentUserId: String) async {
        guard let db else { return }
        let trimmedUserId = currentUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserId.isEmpty else { return }

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

            await refreshUnreadForClient(userId: trimmedUserId)
        } catch {
            print("Mark read failed: \(error)")
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

    private static func parseConversations(from documents: [QueryDocumentSnapshot]) -> [ChatConversation] {
        documents.compactMap { document -> ChatConversation? in
            let data = document.data()
            guard let coachId = data["coachId"] as? String,
                  let userId = data["userId"] as? String,
                  let coachName = data["coachName"] as? String,
                  let userName = data["userName"] as? String else { return nil }

            return ChatConversation(
                id: document.documentID,
                coachId: coachId,
                userId: userId,
                coachName: coachName,
                userName: userName,
                lastMessage: CoachPlaceholderContent.sanitizedMessage(
                    data["lastMessage"] as? String ?? ""
                ),
                lastMessageAt: (data["lastMessageAt"] as? Timestamp)?.dateValue() ?? .distantPast
            )
        }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
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
}
