import SwiftUI

private enum CoachCardColors {
    static let background = Color(red: 15 / 255, green: 26 / 255, blue: 15 / 255)
    static let border = Color(red: 30 / 255, green: 58 / 255, blue: 30 / 255)
    static let accent = SyncFitTheme.primaryAction
    static let mutedGreen = Color(red: 58 / 255, green: 90 / 255, blue: 58 / 255)
    static let pillBackground = Color(red: 26 / 255, green: 58 / 255, blue: 26 / 255)
    static let statBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let mutedGray = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)
    static let bodyGray = Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255)
}

struct SyncFitAICoachCard: View {
    let model: SyncFitCoachCardModel
    let isPremium: Bool
    let onViewPlan: () -> Void

    var body: some View {
        Group {
            if isPremium {
                premiumCoachCard
            } else {
                freeUserCoachCard
            }
        }
    }

    private var freeUserCoachCard: some View {
        Button(action: onViewPlan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    brandHeader

                    Spacer(minLength: 8)

                    Text(SyncFitPlusBrand.unlockButton)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(CoachCardColors.accent)
                        .clipShape(Capsule())
                }

                Text(SyncFitPlusBrand.freeUserPitch)
                    .font(.system(size: 12))
                    .foregroundStyle(CoachCardColors.bodyGray)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(CoachCardColors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CoachCardColors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var premiumCoachCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                brandHeader

                Spacer(minLength: 8)

                Button(action: onViewPlan) {
                    Text(SyncFitPlusBrand.openAICoachButton)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CoachCardColors.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(CoachCardColors.pillBackground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 8) {
                proteinStatBlock
                    .frame(maxWidth: .infinity)
                CoachStatBlock(
                    value: model.volume.primaryText,
                    label: model.volume.label,
                    delta: model.volume.deltaText,
                    valueColor: .white
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CoachCardColors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CoachCardColors.border, lineWidth: 0.5)
        )
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SyncFitPlusBrand.labeledTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoachCardColors.accent)
            Text(SyncFitPlusBrand.subscriberTagline)
                .font(.system(size: 9))
                .foregroundStyle(CoachCardColors.mutedGreen)
        }
    }

    private var proteinStatBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.protein.primaryText)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(model.protein.goalHit ? CoachCardColors.accent : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(model.protein.label)
                .font(.system(size: 9))
                .foregroundStyle(CoachCardColors.mutedGray)
                .lineLimit(1)

            if let delta = model.protein.deltaText {
                Text(delta)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CoachCardColors.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CoachCardColors.statBackground)
        )
    }
}

private struct CoachStatBlock: View {
    let value: String
    let label: String
    let delta: String?
    var valueColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(CoachCardColors.mutedGray)
                .lineLimit(1)

            if let delta {
                Text(delta)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CoachCardColors.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CoachCardColors.statBackground)
        )
    }
}
