import XCTest
@testable import SyncFit

@MainActor
final class SavedMealManualMacrosTests: XCTestCase {
    func testManualMacroMealPersistsTotalsAndLogsAsFoodEntry() throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let store = FitnessDataStore(context: container.mainContext)

        let mealName = "Manual Macro Bowl"
        let meal = SavedMeal(
            name: mealName,
            components: [
                MealComponent(
                    name: mealName,
                    amount: "",
                    calories: 520,
                    protein: 42,
                    carbs: 48,
                    fat: 14
                )
            ]
        )

        store.addSavedMeal(meal)

        let saved = try XCTUnwrap(store.savedMeals.first { $0.name == mealName })
        XCTAssertEqual(saved.totalCalories, 520)
        XCTAssertEqual(saved.totalProtein, 42)
        XCTAssertEqual(saved.totalCarbs, 48)
        XCTAssertEqual(saved.totalFat, 14)
        XCTAssertEqual(saved.components.count, 1, "Manual meals store macros as one component, not an ingredient list")

        let logDate = Calendar.current.startOfDay(for: Date())
        store.logSavedMeal(saved, as: .dinner, on: logDate)

        let logged = store.foods.filter {
            $0.name == mealName && Calendar.current.isDate($0.date, inSameDayAs: logDate)
        }
        XCTAssertEqual(logged.count, 1)
        let entry = try XCTUnwrap(logged.first)
        XCTAssertEqual(entry.calories, 520)
        XCTAssertEqual(entry.protein, 42)
        XCTAssertEqual(entry.carbs, 48)
        XCTAssertEqual(entry.fat, 14)
        XCTAssertEqual(entry.meal, .dinner)
    }

    func testEmptyComponentsWouldZeroTotals_soEditorMustPersistMacrosComponent() {
        let empty = SavedMeal(name: "Broken", components: [])
        XCTAssertEqual(empty.totalCalories, 0)
        XCTAssertEqual(empty.totalProtein, 0)

        let manual = SavedMeal(
            name: "OK",
            components: [MealComponent(name: "OK", calories: 100, protein: 10, carbs: 5, fat: 2)]
        )
        XCTAssertEqual(manual.totalCalories, 100)
        XCTAssertEqual(manual.totalProtein, 10)
    }
}
