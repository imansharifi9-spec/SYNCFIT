import SwiftUI

enum CoachUIColor {
    static let page = Color(red: CoachStyle.pageBackground.red, green: CoachStyle.pageBackground.green, blue: CoachStyle.pageBackground.blue)
    static let card = Color(red: CoachStyle.cardBackground.red, green: CoachStyle.cardBackground.green, blue: CoachStyle.cardBackground.blue)
    static let border = Color(red: CoachStyle.cardBorder.red, green: CoachStyle.cardBorder.green, blue: CoachStyle.cardBorder.blue)
    static let accent = SyncFitTheme.primaryAction
    static let chipActive = SyncFitTheme.primaryAction
    static let chipInactiveBackground = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
    static let chipInactiveText = Color(red: 102 / 255, green: 102 / 255, blue: 102 / 255)
    static let chipInactiveBorder = Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)
    static let chipBorder = Color(red: CoachStyle.chipInactiveBorder.red, green: CoachStyle.chipInactiveBorder.green, blue: CoachStyle.chipInactiveBorder.blue)
    static let subtitle = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)
    static let testimonialCard = Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255)
    static let countAmber = Color(red: 230 / 255, green: 180 / 255, blue: 80 / 255)
    static let countRed = Color(red: 224 / 255, green: 112 / 255, blue: 112 / 255)
    static let errorRed = Color(red: 235 / 255, green: 90 / 255, blue: 90 / 255)
    static let muted = Color(red: CoachStyle.muted.red, green: CoachStyle.muted.green, blue: CoachStyle.muted.blue)
    static let section = Color(red: CoachStyle.sectionLabel.red, green: CoachStyle.sectionLabel.green, blue: CoachStyle.sectionLabel.blue)
    static let footer = Color(red: CoachStyle.footerLink.red, green: CoachStyle.footerLink.green, blue: CoachStyle.footerLink.blue)
    static let verified = Color(red: CoachStyle.verifiedBlue.red, green: CoachStyle.verifiedBlue.green, blue: CoachStyle.verifiedBlue.blue)
    static let aiBackground = Color(red: CoachStyle.aiCardBackground.red, green: CoachStyle.aiCardBackground.green, blue: CoachStyle.aiCardBackground.blue)
    static let aiBorder = Color(red: CoachStyle.aiCardBorder.red, green: CoachStyle.aiCardBorder.green, blue: CoachStyle.aiCardBorder.blue)
}

struct CoachFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

extension String {
    var coachInitials: String {
        let parts = split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }
}
