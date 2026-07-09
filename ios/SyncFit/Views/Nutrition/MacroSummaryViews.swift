import SwiftUI

struct MacroSummaryView: View {
    let style: NutritionMacroDisplayStyle
    let title: String
    let calories: MacroProgress
    let protein: MacroProgress
    let carbs: MacroProgress
    let fat: MacroProgress

    var body: some View {
        SyncFitCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.headline)

                switch style {
                case .rings:
                    MacroRingsGrid(
                        calories: calories,
                        protein: protein,
                        carbs: carbs,
                        fat: fat
                    )
                case .bars:
                    MacroBarsGrid(
                        calories: calories,
                        protein: protein,
                        carbs: carbs,
                        fat: fat
                    )
                }
            }
        }
    }
}

struct MacroProgress {
    let current: Int
    let target: Int
    let label: String
    let unit: String
    let color: Color

    var progress: Double {
        guard target > 0 else { return 0 }
        return Double(current) / Double(target)
    }
}

private struct MacroRingsGrid: View {
    let calories: MacroProgress
    let protein: MacroProgress
    let carbs: MacroProgress
    let fat: MacroProgress

    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            MacroRingCell(macro: calories)
            MacroRingCell(macro: protein)
            MacroRingCell(macro: carbs)
            MacroRingCell(macro: fat)
        }
    }
}

private struct MacroRingCell: View {
    let macro: MacroProgress

    @Environment(\.colorScheme) private var colorScheme

    private var isCalories: Bool {
        macro.label.caseInsensitiveCompare("Calories") == .orderedSame
    }

    var body: some View {
        VStack(spacing: 8) {
            if isCalories {
                let calorieDisplay = CalorieGoalDisplay(current: macro.current, target: macro.target)
                ProgressRingView(
                    progress: calorieDisplay.ringProgress,
                    color: calorieDisplay.ringColor,
                    lineWidth: 7,
                    size: 78
                ) {
                    VStack(spacing: 0) {
                        Text("\(macro.current)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }

                VStack(spacing: 2) {
                    Text(macro.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(calorieDisplay.subtitle)
                        .font(.caption2)
                        .foregroundStyle(
                            calorieDisplay.isOverTarget
                                ? SyncFitTheme.calorieOver
                                : Color.secondary
                        )
                }
            } else {
                ProgressRingView(
                    progress: macro.progress,
                    color: macro.color,
                    lineWidth: 7,
                    size: 78
                ) {
                    VStack(spacing: 0) {
                        Text("\(macro.current)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        if !macro.unit.isEmpty {
                            Text(macro.unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(macro.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("of \(macro.target)\(macro.unit)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MacroBarsGrid: View {
    let calories: MacroProgress
    let protein: MacroProgress
    let carbs: MacroProgress
    let fat: MacroProgress

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            MacroBarRow(macro: calories)
            MacroBarRow(macro: protein)
            MacroBarRow(macro: carbs)
            MacroBarRow(macro: fat)
        }
    }
}

private struct MacroBarRow: View {
    let macro: MacroProgress

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(macro.label)
                Spacer()
                Text("\(macro.current)\(macro.unit) / \(macro.target)\(macro.unit)")
                    .foregroundStyle(SyncFitTheme.detailText(for: colorScheme))
            }
            .font(.subheadline)

            ProgressView(value: min(macro.progress, 1))
                .tint(macro.color)
        }
    }
}

struct NutritionDisplaySettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Macro display")
                .font(.subheadline.weight(.semibold))

            Picker("Macro display", selection: Binding(
                get: { appState.nutritionMacroDisplayStyle },
                set: { appState.setNutritionMacroDisplayStyle($0) }
            )) {
                ForEach(NutritionMacroDisplayStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text(appState.nutritionMacroDisplayStyle.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            MacroDisplayPreview(style: appState.nutritionMacroDisplayStyle)
        }
    }
}

private struct MacroDisplayPreview: View {
    let style: NutritionMacroDisplayStyle

    private let sampleCalories = MacroProgress(current: 1420, target: 2200, label: "Calories", unit: "", color: SyncFitTheme.accent)
    private let sampleProtein = MacroProgress(current: 98, target: 160, label: "Protein", unit: "g", color: SyncFitTheme.protein)
    private let sampleCarbs = MacroProgress(current: 120, target: 220, label: "Carbs", unit: "g", color: SyncFitTheme.carbs)
    private let sampleFat = MacroProgress(current: 42, target: 70, label: "Fat", unit: "g", color: SyncFitTheme.fat)

    var body: some View {
        Group {
            switch style {
            case .rings:
                MacroRingsGrid(
                    calories: sampleCalories,
                    protein: sampleProtein,
                    carbs: sampleCarbs,
                    fat: sampleFat
                )
            case .bars:
                MacroBarsGrid(
                    calories: sampleCalories,
                    protein: sampleProtein,
                    carbs: sampleCarbs,
                    fat: sampleFat
                )
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
