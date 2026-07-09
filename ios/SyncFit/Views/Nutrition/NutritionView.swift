import SwiftUI

struct NutritionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dataStore: FitnessDataStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedDate = Date.now
    @State private var followsToday = true
    @State private var showingFoodSearch = false
    @State private var foodSearchScopedMeal: MealType?
    @State private var foodSearchLogDate = Date.now
    @State private var editingFood: FoodEntry?

    @AppStorage("nutrition.meal.expanded.breakfast") private var breakfastExpanded = true
    @AppStorage("nutrition.meal.expanded.lunch") private var lunchExpanded = true
    @AppStorage("nutrition.meal.expanded.dinner") private var dinnerExpanded = true
    @AppStorage("nutrition.meal.expanded.snack") private var snacksExpanded = true

    private var dayFoods: [FoodEntry] {
        dataStore.foods(on: selectedDate)
    }

    private var dayMacros: (calories: Int, protein: Int, carbs: Int, fat: Int) {
        dataStore.macroTotals(for: dayFoods)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NutritionWeekStrip(
                        selectedDate: $selectedDate,
                        hasLoggedFood: { !dataStore.foods(on: $0).isEmpty }
                    )

                    NutritionMacroHeroCard(
                        calories: macroProgress(
                            current: dayMacros.calories,
                            target: appState.profile.calorieTarget,
                            label: "Calories",
                            color: SyncFitTheme.accent
                        ),
                        protein: macroProgress(
                            current: dayMacros.protein,
                            target: appState.profile.proteinTarget,
                            label: "Protein",
                            color: SyncFitTheme.protein
                        ),
                        carbs: macroProgress(
                            current: dayMacros.carbs,
                            target: appState.profile.carbTarget,
                            label: "Carbs",
                            color: SyncFitTheme.carbs
                        ),
                        fat: macroProgress(
                            current: dayMacros.fat,
                            target: appState.profile.fatTarget,
                            label: "Fat",
                            color: SyncFitTheme.fat
                        )
                    )

                    VStack(spacing: 10) {
                        ForEach(MealType.mealSections) { meal in
                            NutritionMealSection(
                                meal: meal,
                                foods: dataStore.foods(on: selectedDate, meal: meal),
                                calories: dataStore.mealCalories(on: selectedDate, meal: meal),
                                isExpanded: binding(for: meal),
                                onAdd: { openFoodSearch(scopedTo: meal) },
                                onDelete: { dataStore.deleteFood($0) },
                                onEdit: { editingFood = $0 }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .background(SyncFitTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NutritionLogFoodStickyCTA {
                    openFoodSearch(scopedTo: nil)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Nutrition")
                            .font(.headline)
                        Text(goalSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showingFoodSearch, onDismiss: {
                foodSearchScopedMeal = nil
            }) {
                FoodSearchSheet(logDate: foodSearchLogDate, scopedMeal: foodSearchScopedMeal)
            }
            .sheet(item: $editingFood) { food in
                EditFoodSheet(food: food)
            }
            .onAppear {
                refreshNutritionDayContext()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refreshNutritionDayContext()
                }
            }
            .onChange(of: selectedDate) { _, newDate in
                followsToday = Calendar.current.isDateInToday(newDate)
            }
        }
    }

    private func refreshNutritionDayContext() {
        dataStore.refreshCurrentCalendarDayIfNeeded()
        if followsToday {
            selectedDate = .now
        }
    }

    private var goalSubtitle: String {
        let current = SyncFitFormat.formattedInteger(dayMacros.calories)
        let target = SyncFitFormat.formattedInteger(appState.profile.calorieTarget)
        if Calendar.current.isDateInToday(selectedDate) {
            return "\(current) / \(target) cal today"
        }
        return "\(current) / \(target) cal"
    }

    private func macroProgress(current: Int, target: Int, label: String, color: Color) -> MacroProgress {
        MacroProgress(current: current, target: target, label: label, unit: label == "Calories" ? "" : "g", color: color)
    }

    private func binding(for meal: MealType) -> Binding<Bool> {
        switch meal {
        case .breakfast: return $breakfastExpanded
        case .lunch: return $lunchExpanded
        case .dinner: return $dinnerExpanded
        case .snack: return $snacksExpanded
        }
    }

    private func openFoodSearch(scopedTo meal: MealType?) {
        foodSearchLogDate = selectedDate
        foodSearchScopedMeal = meal
        showingFoodSearch = true
    }
}

private struct NutritionMealSection: View {
    let meal: MealType
    let foods: [FoodEntry]
    let calories: Int
    @Binding var isExpanded: Bool
    let onAdd: () -> Void
    let onDelete: (FoodEntry) -> Void
    let onEdit: (FoodEntry) -> Void

    private let cardBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(meal.sectionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(calories) cal")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    if foods.isEmpty {
                        Text("No foods logged")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    } else {
                        List {
                            ForEach(foods) { food in
                                Button {
                                    onEdit(food)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(food.name)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(food.detailLine)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color(red: 136 / 255, green: 136 / 255, blue: 136 / 255))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        onDelete(food)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(height: CGFloat(foods.count) * 52 + 8)
                    }

                    Button(action: onAdd) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.caption.weight(.bold))
                            Text("Add food")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(SyncFitTheme.accentBright)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct NutritionLogFoodStickyCTA: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                Text("Log food")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SyncFitTheme.accentBright)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
    }
}

#Preview {
    NutritionView()
        .environmentObject(AppState.preview())
        .environmentObject(FitnessDataStore.preview())
}
