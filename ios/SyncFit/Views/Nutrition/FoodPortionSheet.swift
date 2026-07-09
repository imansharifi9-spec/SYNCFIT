import SwiftUI

enum FoodAmountUnit: String, CaseIterable, Identifiable {
    case grams
    case oz
    case cups
    case pieces
    case servings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grams: return "g"
        case .oz: return "oz"
        case .cups: return "cups"
        case .pieces: return "pieces"
        case .servings: return "servings"
        }
    }

    func toGrams(_ value: Double, servingGrams: Double?) -> Double {
        switch self {
        case .grams: return value
        case .oz: return value * 28.3495
        case .cups: return value * 240
        case .pieces: return value * (servingGrams ?? 50)
        case .servings: return value * (servingGrams ?? 100)
        }
    }

    func servingLabel(amount: Double) -> String {
        let rounded = SyncFitFormat.decimal(amount)
        switch self {
        case .grams: return "\(rounded)g"
        case .oz: return "\(rounded) oz"
        case .cups: return rounded == "1" ? "1 cup" : "\(rounded) cups"
        case .pieces: return rounded == "1" ? "1 piece" : "\(rounded) pieces"
        case .servings: return rounded == "1" ? "1 serving" : "\(rounded) servings"
        }
    }
}

struct FoodPortionView: View {
    @EnvironmentObject private var dataStore: FitnessDataStore

    let item: FoodLibraryItem
    let logDate: Date
    let locksMeal: Bool
    var onIngredientAdded: ((MealComponent) -> Void)?
    var onLogged: () -> Void

    @State private var meal: MealType
    @State private var amountText = "100"
    @State private var unit: FoodAmountUnit = .grams
    @FocusState private var amountFocused: Bool

    init(
        item: FoodLibraryItem,
        logDate: Date,
        selectedMeal: MealType,
        locksMeal: Bool = false,
        onIngredientAdded: ((MealComponent) -> Void)? = nil,
        onLogged: @escaping () -> Void
    ) {
        self.item = item
        self.logDate = logDate
        self.locksMeal = locksMeal
        self.onIngredientAdded = onIngredientAdded
        self.onLogged = onLogged
        _meal = State(initialValue: selectedMeal)
    }

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var scaled: (calories: Int, protein: Int, carbs: Int, fat: Int) {
        let grams = unit.toGrams(amount, servingGrams: item.servingGrams)
        guard grams > 0 else { return (0, 0, 0, 0) }
        if item.isPerServing, unit == .servings, let perServing = item.scaled(servings: amount) {
            return perServing
        }
        return item.scaled(to: grams)
    }

    private var confirmButtonTitle: String {
        if onIngredientAdded != nil { return "Add Ingredient" }
        return "Add to \(meal.sectionTitle)"
    }

    private var showsMealPicker: Bool {
        onIngredientAdded == nil && !locksMeal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.name)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)

            if let brand = item.brand, !brand.isEmpty, brand != "Recent" {
                Text(brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }

            servingInput
                .padding(.bottom, 20)

            macroStatGrid
                .padding(.bottom, showsMealPicker ? 20 : 16)

            if showsMealPicker {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add to:")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MealPillPicker(selection: $meal)
                }
                .padding(.bottom, 16)
            }

            Button(confirmButtonTitle) {
                save()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(amount <= 0 || scaled.calories <= 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SyncFitTheme.background)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if item.isPerServing {
                unit = .servings
                amountText = "1"
            } else {
                unit = .grams
                amountText = "100"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                amountFocused = true
            }
        }
    }

    private var servingInput: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("0", text: $amountText)
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    amountFocused = true
                }

            Picker("Unit", selection: $unit) {
                ForEach(availableUnits) { unit in
                    Text(unit.label).tag(unit)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .background(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var macroStatGrid: some View {
        HStack(spacing: 8) {
            MacroStatBlock(label: "Calories", value: "\(scaled.calories)")
            MacroStatBlock(label: "Protein", value: "\(scaled.protein)g")
            MacroStatBlock(label: "Carbs", value: "\(scaled.carbs)g")
            MacroStatBlock(label: "Fat", value: "\(scaled.fat)g")
        }
    }

    private var availableUnits: [FoodAmountUnit] {
        if item.isPerServing || item.servingGrams != nil {
            return [.grams, .oz, .servings, .cups, .pieces]
        }
        return [.grams, .oz, .cups, .pieces]
    }

    private func save() {
        let serving = unit.servingLabel(amount: amount)

        if let onIngredientAdded {
            onIngredientAdded(
                MealComponent(
                    name: item.name,
                    amount: serving,
                    calories: scaled.calories,
                    protein: scaled.protein,
                    carbs: scaled.carbs,
                    fat: scaled.fat
                )
            )
        } else {
            let entry = FoodEntry(
                name: item.name,
                calories: scaled.calories,
                protein: scaled.protein,
                carbs: scaled.carbs,
                fat: scaled.fat,
                meal: meal,
                date: Calendar.current.startOfDay(for: logDate),
                servingLabel: serving
            )
            dataStore.addFood(entry)
        }
        onLogged()
    }
}

private struct MacroStatBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MealPillPicker: View {
    @Binding var selection: MealType

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MealType.mealSections) { meal in
                    Button {
                        selection = meal
                    } label: {
                        Text(meal.sectionTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selection == meal ? .white : Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(selection == meal ? SyncFitTheme.accentBright : Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
