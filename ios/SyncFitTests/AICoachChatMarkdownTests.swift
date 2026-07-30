import XCTest
@testable import SyncFit

final class AICoachChatMarkdownTests: XCTestCase {
    func testParsesHeadersBoldAndBulletedList() throws {
        let markdown = """
        # Focus this week

        Prioritize **protein consistency** and recovery.

        - Hit your daily protein target
        - Progress one compound lift
        - Sleep 7+ hours
        """

        let attributed = AICoachChatMarkdown.attributedString(from: markdown)
        let plain = String(attributed.characters)

        // Raw Markdown markers should not remain in the rendered plain text.
        XCTAssertFalse(plain.contains("**"), "Bold markers should be consumed by the parser")
        XCTAssertFalse(plain.contains("# Focus"), "Header hash should be consumed by the parser")
        XCTAssertTrue(plain.contains("Focus this week"))
        XCTAssertTrue(plain.contains("protein consistency"))
        XCTAssertTrue(plain.contains("Hit your daily protein target"))
        XCTAssertTrue(plain.contains("Progress one compound lift"))

        var sawBold = false
        var sawHeader = false
        var sawListItem = false

        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                sawBold = true
            }
            if run.presentationIntent?.components.contains(where: {
                if case .header = $0.kind { return true }
                return false
            }) == true {
                sawHeader = true
            }
            if run.presentationIntent?.components.contains(where: {
                if case .listItem = $0.kind { return true }
                return false
            }) == true {
                sawListItem = true
            }
        }

        XCTAssertTrue(sawBold, "Expected stronglyEmphasized intent for **protein consistency**")
        XCTAssertTrue(sawHeader, "Expected header presentation intent for # Focus this week")
        XCTAssertTrue(sawListItem, "Expected listItem presentation intent for bulleted lines")
    }

    func testSingleNewlinesBecomeSeparateSpacedBlocks() {
        // Mirrors the production bug: Claude used single newlines, so
        // "Strategy for You" + "Since you're..." rendered as one dense run.
        let dense = [
            "## Progressive Overload Strategy for You",
            "Since you're beginner experience, start with **two hard sets**.",
            "## Focus this week",
            "- Hit protein daily",
            "- Progress one compound lift",
            "- Sleep 7+ hours",
        ].joined(separator: "\n")

        let normalized = AICoachChatMarkdown.normalizeParagraphBreaks(dense)
        XCTAssertTrue(
            normalized.contains("You\n\nSince"),
            "Header and following paragraph must be separated by a blank line"
        )
        XCTAssertTrue(
            normalized.contains("week\n\n- Hit"),
            "Header and first list item must be separated by a blank line"
        )
        XCTAssertFalse(normalized.contains("YouSince"))

        let blocks = AICoachChatMarkdown.blocks(from: dense)
        // Header, body, header, then three bullets → clear visual sections.
        XCTAssertGreaterThanOrEqual(blocks.count, 5, "Expected multiple spaced blocks, got \(blocks)")
        XCTAssertEqual(blocks[0], "## Progressive Overload Strategy for You")
        XCTAssertTrue(blocks[1].hasPrefix("Since you're beginner experience"))
        XCTAssertTrue(blocks[1].contains("**two hard sets**"))
        XCTAssertEqual(blocks[2], "## Focus this week")
        XCTAssertTrue(blocks.contains("- Hit protein daily"))
        XCTAssertTrue(blocks.contains("- Sleep 7+ hours"))

        // Adjacent blocks must not glue header text into the next sentence.
        XCTAssertFalse(blocks.contains(where: { $0.contains("YouSince") }))

        let body = AICoachChatMarkdown.attributedString(from: blocks[1], normalize: false)
        XCTAssertTrue(
            body.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
            "Bold inside a spaced block should still parse"
        )
        let header = AICoachChatMarkdown.attributedString(from: blocks[0], normalize: false)
        XCTAssertTrue(
            header.runs.contains { run in
                run.presentationIntent?.components.contains(where: {
                    if case .header = $0.kind { return true }
                    return false
                }) == true
            },
            "Header block should keep header presentation intent"
        )
    }

    func testDoesNotInflateAlreadySpacedMarkdown() {
        let spaced = "# Title\n\nParagraph one.\n\n- A\n\n- B"
        let normalized = AICoachChatMarkdown.normalizeParagraphBreaks(spaced)
        XCTAssertFalse(
            normalized.contains("\n\n\n"),
            "Preprocessing should not create triple+ blank lines"
        )
        XCTAssertEqual(normalized, "# Title\n\nParagraph one.\n\n- A\n\n- B")
        XCTAssertEqual(
            AICoachChatMarkdown.blocks(from: spaced),
            ["# Title", "Paragraph one.", "- A", "- B"]
        )
    }

    func testFallsBackToPlainTextWhenMarkdownIsInvalid() {
        // Unclosed fence / odd input should not crash — returns plain AttributedString.
        let attributed = AICoachChatMarkdown.attributedString(from: "Just plain advice")
        XCTAssertEqual(String(attributed.characters), "Just plain advice")
    }

    func testAttributedBlockParsesBoldInsideSplitBulletLine() {
        // Insights (and chat blocks) split single-newline bullets into separate blocks;
        // standalone "- **text**" must still render bold, not literal asterisks.
        let block = "- **Exceptional workout consistency**"
        let attributed = AICoachChatMarkdown.attributedBlock(from: block)
        let plain = String(attributed.characters)

        XCTAssertFalse(plain.contains("**"), "Bold markers should be consumed")
        XCTAssertTrue(plain.contains("Exceptional workout consistency"))
        XCTAssertTrue(
            attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
            "Expected bold intent inside a split bullet block"
        )
    }
}
