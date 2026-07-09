import SwiftUI

struct CalorieTargetPlannerView: View {
    @Binding var profile: UserProfile
    @Binding var selectedOptionID: String?

    init(profile: Binding<UserProfile>, selectedOptionID: Binding<String?> = .constant(nil)) {
        _profile = profile
        _selectedOptionID = selectedOptionID
    }

    private var result: CalorieCalculator.Result {
        CalorieCalculator.calculate(for: profile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            summaryCard

            Text(planSectionTitle)
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(result.options) { option in
                    paceRow(option)
                }
            }

            Text("Based on the Mifflin–St Jeor equation and your activity level. Adjust anytime in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var planSectionTitle: String {
        switch profile.goal {
        case .loseFat: return "Choose your fat-loss pace"
        case .buildMuscle: return "Choose your bulk pace"
        default: return "Your calorie target"
        }
    }

    private var summaryCard: some View {
        SyncFitCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your metabolism")
                    .font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BMR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(result.bmr)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(SyncFitTheme.accent)
                        Text("cal at rest")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Maintenance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(result.maintenance)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(SyncFitTheme.accentBright)
                        Text("cal to maintain")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Activity: \(profile.activityLevel.rawValue) · \(profile.activityLevel.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func paceRow(_ option: CalorieCalculator.PaceOption) -> some View {
        let isSelected = selectedOptionID == option.id
            || (selectedOptionID == nil && profile.calorieTarget == option.calories)

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                selectedOptionID = option.id
                profile.applyMacroTargets(calories: option.calories)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(option.calories)")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(SyncFitTheme.accent)
                    Text("cal/day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? SyncFitTheme.accent : Color(.tertiaryLabel))
                    .padding(.top, 4)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? SyncFitTheme.accent.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? SyncFitTheme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SimpleMacroTargetsView: View {
    @Binding var profile: UserProfile

    var body: some View {
        VStack(spacing: 12) {
            macroField("Calories", value: $profile.calorieTarget)
            macroField("Protein (g)", value: $profile.proteinTarget)
            macroField("Carbs (g)", value: $profile.carbTarget)
            macroField("Fat (g)", value: $profile.fatTarget)

            let maintenance = CalorieCalculator.calculate(for: profile).maintenance
            Text("Estimated maintenance: \(maintenance) cal/day")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func macroField(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
        .padding()
        .background(SyncFitTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
