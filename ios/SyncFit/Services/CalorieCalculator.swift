import Foundation

/// Mifflin–St Jeor BMR + standard activity multipliers. ~3,500 kcal per lb body-weight change.
enum CalorieCalculator {
    struct PaceOption: Identifiable, Hashable {
        let id: String
        let title: String
        let detail: String
        let weeklyChangeLbs: Double
        let calories: Int
        let isMaintenance: Bool
    }

    struct Result {
        let bmr: Int
        let maintenance: Int
        let options: [PaceOption]
    }

    private static let kcalPerPound: Double = 3500
    private static let daysPerWeek: Double = 7

    static func calculate(for profile: UserProfile) -> Result {
        let bmr = basalMetabolicRate(profile: profile)
        let maintenance = Int((Double(bmr) * profile.activityLevel.multiplier).rounded())
        let options = paceOptions(goal: profile.goal, maintenance: maintenance, profile: profile)
        return Result(bmr: bmr, maintenance: maintenance, options: options)
    }

    static func applyRecommendedTargets(to profile: inout UserProfile, selectedOptionID: String? = nil) {
        let result = calculate(for: profile)

        if profile.goal.usesCaloriePlanner {
            let defaultID = profile.goal == .loseFat ? "loss-moderate" : "gain-slow"
            let optionID = selectedOptionID ?? defaultID
            if let option = result.options.first(where: { $0.id == optionID }) {
                profile.applyMacroTargets(calories: option.calories)
            } else if let maintenance = result.options.first(where: { $0.isMaintenance }) {
                profile.applyMacroTargets(calories: maintenance.calories)
            }
        } else {
            profile.applyMacroTargets(calories: result.maintenance)
        }
    }

    static func basalMetabolicRate(profile: UserProfile) -> Int {
        let weight = profile.bodyWeightKg
        let height = profile.heightCm
        let age = Double(max(profile.age, 14))

        let base = 10 * weight + 6.25 * height - 5 * age
        let sexOffset: Double
        switch profile.gender {
        case .male: sexOffset = 5
        case .female: sexOffset = -161
        case .other, .preferNotToSay: sexOffset = -78
        }
        return max(Int((base + sexOffset).rounded()), 1000)
    }

    private static func paceOptions(goal: FitnessGoal, maintenance: Int, profile: UserProfile) -> [PaceOption] {
        var options: [PaceOption] = [
            PaceOption(
                id: "maintenance",
                title: "Maintain weight",
                detail: "Eat at maintenance to stay at your current weight.",
                weeklyChangeLbs: 0,
                calories: maintenance,
                isMaintenance: true
            )
        ]

        let paces: [(id: String, lbs: Double, label: String, intensity: String)] = [
            ("slow", 0.5, "0.5 lb per week", "Sustainable"),
            ("moderate", 1.0, "1 lb per week", "Standard"),
            ("aggressive", 2.0, "2 lbs per week", "Aggressive")
        ]

        switch goal {
        case .loseFat:
            for pace in paces {
                let deficit = Int((pace.lbs * kcalPerPound / daysPerWeek).rounded())
                let raw = maintenance - deficit
                let calories = safeCalories(raw, maintenance: maintenance, profile: profile, isDeficit: true)
                options.append(
                    PaceOption(
                        id: "loss-\(pace.id)",
                        title: "Lose \(pace.label)",
                        detail: "\(pace.intensity) · \(deficit) cal below maintenance",
                        weeklyChangeLbs: -pace.lbs,
                        calories: calories,
                        isMaintenance: false
                    )
                )
            }
        case .buildMuscle:
            for pace in paces {
                let surplus = Int((pace.lbs * kcalPerPound / daysPerWeek).rounded())
                let calories = maintenance + surplus
                options.append(
                    PaceOption(
                        id: "gain-\(pace.id)",
                        title: "Gain \(pace.label)",
                        detail: "\(pace.intensity) · \(surplus) cal above maintenance",
                        weeklyChangeLbs: pace.lbs,
                        calories: calories,
                        isMaintenance: false
                    )
                )
            }
        case .gainStrength, .healthyLifestyle:
            break
        }

        return options
    }

    private static func safeCalories(
        _ calories: Int,
        maintenance: Int,
        profile: UserProfile,
        isDeficit: Bool
    ) -> Int {
        let genderFloor = profile.gender == .female ? 1200 : 1500
        let maxDeficit = Int((Double(maintenance) * 0.35).rounded())
        let floorFromDeficit = isDeficit ? maintenance - maxDeficit : genderFloor
        let floor = max(genderFloor, floorFromDeficit)
        return max(calories, floor)
    }
}
