import SwiftUI

struct NutritionMacroHeroCard: View {
    let calories: MacroProgress
    let protein: MacroProgress
    let carbs: MacroProgress
    let fat: MacroProgress

    private let cardBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    private let barTrack = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    private let goalLabelColor = Color(red: 102 / 255, green: 102 / 255, blue: 102 / 255)

    private let proteinFill = Color(red: 92 / 255, green: 219 / 255, blue: 110 / 255)
    private let carbsFill = Color(red: 106 / 255, green: 171 / 255, blue: 238 / 255)

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                let calorieDisplay = CalorieGoalDisplay(current: calories.current, target: calories.target)
                ProgressRingView(
                    progress: calorieDisplay.ringProgress,
                    color: calorieDisplay.ringColor,
                    lineWidth: 8,
                    size: 100
                ) {
                    VStack(spacing: 2) {
                        Text(SyncFitFormat.formattedInteger(calories.current))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(calorieDisplay.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(
                                calorieDisplay.isOverTarget
                                    ? SyncFitTheme.calorieOver
                                    : goalLabelColor
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 8) {
                macroBar(macro: protein, fill: proteinFill, tintValue: false)
                macroBar(macro: carbs, fill: carbsFill, tintValue: false)
                macroBar(macro: fat, fill: SyncFitTheme.fat, tintValue: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func macroBar(macro: MacroProgress, fill: Color, tintValue: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(macro.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(goalLabelColor)

            Text("\(macro.current)g")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tintValue ? fill : .white)
                .lineLimit(1)

            Text("of \(macro.target)g")
                .font(.system(size: 11))
                .foregroundStyle(goalLabelColor)

            macroProgressBar(progress: macro.progress, fill: fill)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macroProgressBar(progress: Double, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(barTrack)
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: min(max(progress, 0), 1), y: 1, anchor: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}
