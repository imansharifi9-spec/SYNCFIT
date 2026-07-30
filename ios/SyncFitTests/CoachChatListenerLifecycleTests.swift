import XCTest
@testable import SyncFit

@MainActor
final class CoachChatListenerLifecycleTests: XCTestCase {

    // MARK: - Participant ID validation

    func testRejectsPlaceholderUUIDParticipantId() {
        let placeholder = UUID().uuidString
        XCTAssertFalse(
            CoachChatService.isValidConversationParticipantId(placeholder),
            "portalProfile.id.uuidString must never be treated as a conversation participant"
        )
        XCTAssertFalse(CoachChatService.isValidConversationParticipantId(""))
        XCTAssertFalse(CoachChatService.isValidConversationParticipantId("   "))
    }

    func testAcceptsFirebaseAuthStyleParticipantId() {
        // Real Auth UIDs are opaque strings without UUID hyphens.
        let authUID = "0FdAAhmqYuWbHz5itJLR8q2hGVj2"
        XCTAssertTrue(CoachChatService.isValidConversationParticipantId(authUID))
        XCTAssertTrue(CoachChatService.isValidConversationParticipantId("UPJizMWxY5RrP6FPioj4ZFZPL393"))
    }

    func testObserveConversationsNeverAttachesOrWipesForPlaceholderUUID() {
        let service = CoachChatService()
        let seeded = ChatConversation(
            id: "a_b",
            coachId: "0FdAAhmqYuWbHz5itJLR8q2hGVj2",
            userId: "UPJizMWxY5RrP6FPioj4ZFZPL393",
            coachName: "Coach",
            userName: "Iman",
            lastMessage: "Hey!",
            lastMessageAt: Date(),
            lastMessageSenderId: "UPJizMWxY5RrP6FPioj4ZFZPL393",
            hasUnreadForViewer: false
        )
        service.conversations = [seeded]
        let genBefore = service.conversationsObservationGenerationForTesting

        service.observeConversations(forParticipant: UUID().uuidString)

        XCTAssertEqual(
            service.conversations.count,
            1,
            "Placeholder observe must not call stopObservingConversations / wipe the list"
        )
        XCTAssertEqual(service.conversations.first?.lastMessage, "Hey!")
        XCTAssertNil(service.unreadMonitorParticipantIdForTesting)
        XCTAssertEqual(
            service.conversationsObservationGenerationForTesting,
            genBefore,
            "Rejected placeholder must not bump conversations generation"
        )
    }

    // MARK: - Messages generation guards

    func testStaleMessagesAttachNeverOverwritesCurrentState() {
        let service = CoachChatService()
        let staleGen = service.beginMessagesObservationSessionForTesting()
        XCTAssertTrue(service.messages.isEmpty)

        // Simulate leave (stop) then re-enter (new session) before stale Task finishes.
        service.stopObservingMessages()
        let liveGen = service.beginMessagesObservationSessionForTesting()
        XCTAssertNotEqual(staleGen, liveGen)

        let liveMessages = [
            ChatMessage(
                id: "m1",
                senderId: "0FdAAhmqYuWbHz5itJLR8q2hGVj2",
                text: "Hey!",
                timestamp: Date()
            )
        ]
        service.applyMessagesSnapshotForTesting(liveMessages, generation: liveGen)
        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.text, "Hey!")

        // Superseded attach from the first tab visit arrives late with empty/wrong data.
        service.applyMessagesSnapshotForTesting([], generation: staleGen)
        XCTAssertEqual(
            service.messages.count,
            1,
            "Stale generation must not wipe messages populated by the live session"
        )
        XCTAssertEqual(service.messages.first?.text, "Hey!")
    }

    func testRapidStopStartDoesNotLeaveMessagesEmptyWhenLiveSnapshotApplies() {
        let service = CoachChatService()

        // Open thread
        let gen1 = service.beginMessagesObservationSessionForTesting()
        service.applyMessagesSnapshotForTesting(
            [
                ChatMessage(
                    id: "m1",
                    senderId: "UPJizMWxY5RrP6FPioj4ZFZPL393",
                    text: "Hello?",
                    timestamp: Date().addingTimeInterval(-60)
                ),
                ChatMessage(
                    id: "m2",
                    senderId: "0FdAAhmqYuWbHz5itJLR8q2hGVj2",
                    text: "Hey!",
                    timestamp: Date()
                )
            ],
            generation: gen1
        )
        XCTAssertEqual(service.messages.count, 2)

        // Rapid tab away → back (stop then start) — mirrors onDisappear / onAppear.
        service.stopObservingMessages()
        XCTAssertTrue(service.messages.isEmpty)

        let gen2 = service.beginMessagesObservationSessionForTesting()
        // Firestore snapshot for the reattach arrives (no new write required).
        service.applyMessagesSnapshotForTesting(
            [
                ChatMessage(
                    id: "m1",
                    senderId: "UPJizMWxY5RrP6FPioj4ZFZPL393",
                    text: "Hello?",
                    timestamp: Date().addingTimeInterval(-60)
                ),
                ChatMessage(
                    id: "m2",
                    senderId: "0FdAAhmqYuWbHz5itJLR8q2hGVj2",
                    text: "Hey!",
                    timestamp: Date()
                )
            ],
            generation: gen2
        )

        XCTAssertEqual(service.messages.count, 2)
        XCTAssertEqual(service.messages.map(\.text), ["Hello?", "Hey!"])
        // Late gen1 snapshot must not clear after reattach.
        service.applyMessagesSnapshotForTesting([], generation: gen1)
        XCTAssertEqual(service.messages.count, 2)
    }

    // MARK: - Conversations generation guards

    func testStaleConversationsAttachNeverOverwritesCurrentState() {
        let service = CoachChatService()
        let authUID = "0FdAAhmqYuWbHz5itJLR8q2hGVj2"
        guard let staleGen = service.beginConversationsObservationSessionForTesting(participantId: authUID) else {
            return XCTFail("Expected valid Auth-backed participant to start a session")
        }

        service.stopObservingConversations()
        guard let liveGen = service.beginConversationsObservationSessionForTesting(participantId: authUID) else {
            return XCTFail("Expected live session")
        }
        XCTAssertNotEqual(staleGen, liveGen)

        let live = [
            ChatConversation(
                id: "0FdAA_UPJiz",
                coachId: authUID,
                userId: "UPJizMWxY5RrP6FPioj4ZFZPL393",
                coachName: "SyncFit",
                userName: "Iman",
                lastMessage: "Hey!",
                lastMessageAt: Date(),
                lastMessageSenderId: authUID,
                hasUnreadForViewer: false
            )
        ]
        service.applyConversationsSnapshotForTesting(live, generation: liveGen)
        XCTAssertEqual(service.conversations.count, 1)

        service.applyConversationsSnapshotForTesting([], generation: staleGen)
        XCTAssertEqual(
            service.conversations.count,
            1,
            "Stale conversations generation must not wipe the live list"
        )
    }

    func testBeginConversationsSessionRejectsPlaceholderWithoutStarting() {
        let service = CoachChatService()
        let result = service.beginConversationsObservationSessionForTesting(
            participantId: UUID().uuidString
        )
        XCTAssertNil(result)
        XCTAssertNil(service.unreadMonitorParticipantIdForTesting)
        XCTAssertEqual(service.conversationsObservationGenerationForTesting, 0)
    }

    // MARK: - Cold-launch attach failure recovery

    func testFailedInitialAttachDoesNotCountAsSettledAlreadyAttached() {
        let service = CoachChatService()
        let authUID = "0FdAAhmqYuWbHz5itJLR8q2hGVj2"
        _ = service.beginConversationsObservationSessionForTesting(participantId: authUID)

        // Reproduce the stuck cold-launch gate: participant bound, "listener" present,
        // but initial attach failed (never healthy).
        service.noteConversationsInitialAttachFailedForTesting(participantId: authUID)

        XCTAssertFalse(
            service.conversationsListenerHealthyForTesting,
            "Failed attach must not mark the listener healthy"
        )
        XCTAssertFalse(
            service.shouldSkipConversationsAttachForTesting(participantId: authUID),
            "Unhealthy attach must not hit the already-attached early return"
        )

        service.noteConversationsAttachSucceededForTesting()
        XCTAssertTrue(service.conversationsListenerHealthyForTesting)
        XCTAssertTrue(
            service.shouldSkipConversationsAttachForTesting(participantId: authUID),
            "Healthy attach should skip redundant re-attach for the same participant"
        )
        service.clearConversationsListenerTestOverrides()
    }

    func testSessionRestoreRetryRestartsAfterFailedColdLaunchAttach() {
        let service = CoachChatService()
        let authUID = "0FdAAhmqYuWbHz5itJLR8q2hGVj2"
        let genBefore = service.beginConversationsObservationSessionForTesting(participantId: authUID) ?? 0
        service.noteConversationsInitialAttachFailedForTesting(participantId: authUID)
        XCTAssertFalse(service.shouldSkipConversationsAttachForTesting(participantId: authUID))

        // Session restore completion must clear the failed identity and allow a new session.
        // Without Firestore this only verifies the retry path clears skip state / bumps gen
        // when startUnreadMonitoring can attach; here we assert the preconditions the
        // production retry uses before calling startUnreadMonitoring.
        XCTAssertEqual(service.unreadMonitorParticipantIdForTesting, authUID)
        XCTAssertFalse(service.conversationsListenerHealthyForTesting)

        // Simulate the retry clearing identity (same as production retry entry).
        service.clearConversationsListenerTestOverrides()
        // Production retry sets unreadMonitorParticipantId = nil then startUnreadMonitoring.
        // Verify a fresh begin after failure advances generation.
        let genAfter = service.beginConversationsObservationSessionForTesting(participantId: authUID)
        XCTAssertNotNil(genAfter)
        XCTAssertGreaterThan(genAfter ?? 0, genBefore)
    }

    func testPendingRetryPreventsStampedeReattach() {
        let service = CoachChatService()
        let authUID = "0FdAAhmqYuWbHz5itJLR8q2hGVj2"
        service.noteConversationsInitialAttachFailedForTesting(participantId: authUID)
        service.noteConversationsRetryTaskPendingForTesting(participantId: authUID)

        XCTAssertFalse(service.shouldSkipConversationsAttachForTesting(participantId: authUID))
        XCTAssertTrue(
            service.shouldWaitForPendingConversationsRetryForTesting(participantId: authUID),
            "Concurrent onAppear must wait for the scheduled cold-launch retry instead of thrashing"
        )
        service.clearConversationsListenerTestOverrides()
        // Cancel the long-sleep test task.
        service.stopObservingConversations()
    }
}
