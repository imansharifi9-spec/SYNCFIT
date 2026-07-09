import SwiftUI
import FirebaseAuth

private struct RoundedCornersShape: Shape {
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
    var bottomRight: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRight),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private enum ChatPalette {
    static let green = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)
    static let userText = Color.black
    static let coachBubble = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let coachText = Color.white
    static let inputBarBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let inputBarBorder = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let fieldBackground = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let timestamp = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)
    static let sendDisabled = Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)
    static let placeholder = Color(red: 102 / 255, green: 102 / 255, blue: 102 / 255)
}

private struct ChatRowItem: Identifiable {
    enum Kind {
        case timestamp(String)
        case message(ChatMessage)
    }

    let id: String
    let kind: Kind
}

struct CoachChatView: View {
    let conversationId: String
    let coachId: String
    let coachName: String
    let coachSpecialty: String
    let userId: String
    let userName: String
    let viewingAsCoach: Bool

    @EnvironmentObject private var chatService: CoachChatService
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var isInputFocused: Bool
    @State private var implementingMessageIDs: Set<String> = []

    private var currentUserId: String? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.72
    }

    private var headerName: String {
        viewingAsCoach ? userName : coachName
    }

    private var otherPartyName: String {
        viewingAsCoach ? userName : coachName
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayRows: [ChatRowItem] {
        buildDisplayRows(from: chatService.messages)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(displayRows) { row in
                        switch row.kind {
                        case .timestamp(let label):
                            Text(label)
                                .font(.system(size: 11))
                                .foregroundStyle(ChatPalette.timestamp)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .id(row.id)

                        case .message(let message):
                            messageRow(
                                message,
                                maxBubbleWidth: maxBubbleWidth,
                                showAvatar: shouldShowAvatar(for: message)
                            )
                            .id(row.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    chatService.startObservingMessages(
                        conversationId: conversationId,
                        coachId: coachId,
                        userId: userId
                    )
                    scrollToBottom(proxy, animated: false)
                    Task {
                        if let currentUserId {
                            await chatService.markConversationRead(
                                conversationId: conversationId,
                                currentUserId: currentUserId
                            )
                        }
                    }
                }
            .onChange(of: chatService.messages) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isInputFocused) { _, focused in
                if focused {
                    scrollToBottom(proxy)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputBar
        }
        .background(CoachUIColor.page)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewingAsCoach ? "Messages" : "Coaches")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(CoachUIColor.accent)
                }
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(headerName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CoachUIColor.accent.opacity(0.85))
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    ChatInitialsAvatar(
                        name: viewingAsCoach ? userName : coachName,
                        specialty: viewingAsCoach ? "" : coachSpecialty,
                        size: 28
                    )
                }
            }
        }
        .onDisappear {
            chatService.stopObservingMessages()
        }
    }

    @ViewBuilder
    private func messageRow(
        _ message: ChatMessage,
        maxBubbleWidth: CGFloat,
        showAvatar: Bool
    ) -> some View {
        let isCurrentUser = isFromCurrentUser(message)

        #if DEBUG
        let _ = print(
            "[ChatBubble] senderId=\(message.normalizedSenderId) currentUserId=\(currentUserId ?? "nil") isCurrentUser=\(isCurrentUser)"
        )
        #endif

        HStack(alignment: .bottom, spacing: 8) {
            if isCurrentUser {
                Spacer(minLength: 0)
                if let payload = message.routineCard {
                    routineCardBubble(payload: payload, message: message, maxWidth: maxBubbleWidth, alignTrailing: true)
                } else {
                    userBubble(text: message.text, maxWidth: maxBubbleWidth)
                }
            } else {
                if showAvatar {
                    ChatInitialsAvatar(
                        name: otherPartyName,
                        specialty: viewingAsCoach ? "" : coachSpecialty,
                        size: 28
                    )
                } else {
                    Color.clear
                        .frame(width: 28, height: 28)
                }

                if let payload = message.routineCard {
                    routineCardBubble(payload: payload, message: message, maxWidth: maxBubbleWidth, alignTrailing: false)
                } else {
                    coachBubble(text: message.text, maxWidth: maxBubbleWidth)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: isCurrentUser ? .trailing : .leading)
        .padding(.vertical, 2)
    }

    private func isFromCurrentUser(_ message: ChatMessage) -> Bool {
        guard let currentUserId else { return false }
        let senderId = message.normalizedSenderId
        if senderId == currentUserId {
            return true
        }
        if viewingAsCoach,
           senderId == coachId.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        return false
    }

    private func routineCardBubble(
        payload: RoutineCardPayload,
        message: ChatMessage,
        maxWidth: CGFloat,
        alignTrailing: Bool
    ) -> some View {
        let template = payload.template
        let isImplemented = payload.isImplemented || implementingMessageIDs.contains(message.id)
        let showImplementButton = !viewingAsCoach && !isImplemented

        return VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Workout Routine", systemImage: "dumbbell.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CoachUIColor.accent)

                Text(template.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text(template.summaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(CoachUIColor.muted)

                if let note = payload.coachNote, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showImplementButton {
                Button {
                    implementRoutine(payload: payload, messageID: message.id)
                } label: {
                    Text(implementingMessageIDs.contains(message.id) ? "Implementing…" : "Implement Routine")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(ChatPalette.green)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .disabled(implementingMessageIDs.contains(message.id))
            } else if isImplemented {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Implemented")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CoachUIColor.accent)
                .frame(maxWidth: .infinity, alignment: alignTrailing ? .trailing : .leading)
            }
        }
        .padding(14)
        .background(ChatPalette.coachBubble)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: maxWidth, alignment: alignTrailing ? .trailing : .leading)
    }

    private func implementRoutine(payload: RoutineCardPayload, messageID: String) {
        guard !viewingAsCoach else { return }
        implementingMessageIDs.insert(messageID)

        dataStore.importProgramTemplate(payload.template.asProgramTemplate(), replaceExisting: true)

        Task {
            let success = await chatService.markRoutineImplemented(
                conversationId: conversationId,
                messageId: messageID,
                payload: payload
            )
            await MainActor.run {
                if success {
                    implementingMessageIDs.remove(messageID)
                } else {
                    implementingMessageIDs.remove(messageID)
                }
            }
        }
    }

    private func userBubble(text: String, maxWidth: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(ChatPalette.userText)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ChatPalette.green)
            .clipShape(
                RoundedCornersShape(
                    topLeft: 18,
                    topRight: 18,
                    bottomLeft: 18,
                    bottomRight: 4
                )
            )
            .frame(maxWidth: maxWidth, alignment: .trailing)
    }

    private func coachBubble(text: String, maxWidth: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(ChatPalette.coachText)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ChatPalette.coachBubble)
            .clipShape(
                RoundedCornersShape(
                    topLeft: 18,
                    topRight: 18,
                    bottomLeft: 4,
                    bottomRight: 18
                )
            )
            .frame(maxWidth: maxWidth, alignment: .leading)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(ChatPalette.inputBarBorder)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ChatPalette.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .focused($isInputFocused)

                Button {
                    sendMessage()
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? ChatPalette.green : ChatPalette.sendDisabled)
                            .frame(width: 32, height: 32)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(canSend ? .white : ChatPalette.placeholder)
                    }
                }
                .disabled(!canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(ChatPalette.inputBarBackground)
        }
    }

    private func sendMessage() {
        guard let currentUserId else { return }
        let text = draft
        draft = ""
        Task {
            let success = await chatService.sendMessage(
                conversationId: conversationId,
                senderId: currentUserId,
                text: text,
                coachId: coachId,
                coachName: coachName,
                userId: userId,
                userName: userName
            )
            if !success {
                draft = text
            }
        }
    }

    private func shouldShowAvatar(for message: ChatMessage) -> Bool {
        guard !isFromCurrentUser(message) else { return false }
        guard let index = chatService.messages.firstIndex(where: { $0.id == message.id }) else { return false }
        let messages = chatService.messages
        let isLastInSequence = index == messages.count - 1
            || messages[index + 1].normalizedSenderId != message.normalizedSenderId
        return isLastInSequence
    }

    private func buildDisplayRows(from messages: [ChatMessage]) -> [ChatRowItem] {
        var rows: [ChatRowItem] = []
        for (index, message) in messages.enumerated() {
            if shouldShowTimestamp(at: index, in: messages) {
                let label = formatTimestamp(message.timestamp)
                rows.append(ChatRowItem(id: "ts-\(message.id)", kind: .timestamp(label)))
            }
            rows.append(ChatRowItem(id: message.id, kind: .message(message)))
        }
        return rows
    }

    private func shouldShowTimestamp(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard index > 0 else { return true }
        let gap = messages[index].timestamp.timeIntervalSince(messages[index - 1].timestamp)
        return gap > 5 * 60
    }

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) {
            return "Today \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(time)"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"
        return "\(dateFormatter.string(from: date)), \(time)"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = displayRows.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

private struct ChatInitialsAvatar: View {
    let name: String
    let specialty: String
    let size: CGFloat

    private var backgroundColor: Color {
        let specialty = specialty.lowercased()
        switch specialty {
        case let s where s.contains("muscle"):
            return Color(red: 0.35, green: 0.2, blue: 0.45)
        case let s where s.contains("fat"), let s where s.contains("weight"):
            return Color(red: 0.2, green: 0.35, blue: 0.45)
        case let s where s.contains("power"):
            return Color(red: 0.45, green: 0.25, blue: 0.2)
        default:
            return Color(red: 0.25, green: 0.35, blue: 0.25)
        }
    }

    var body: some View {
        Text(name.coachInitials)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(backgroundColor)
            .clipShape(Circle())
    }
}

struct CoachChatRoute: Hashable {
    let conversationId: String
    let coachId: String
    let coachName: String
    let coachSpecialty: String
    let userId: String
    let userName: String
}
