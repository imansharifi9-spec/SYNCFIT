import XCTest
@testable import SyncFit

@MainActor
final class FoodLogAwaitingCloudTests: XCTestCase {
    func testAddFoodAwaitingCloudFailsWithoutFirestoreAndDoesNotLeaveLocalEntry() async throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let store = FitnessDataStore(context: container.mainContext)
        store.firestore = nil

        let entry = FoodEntry(
            name: "The Founder",
            calories: 640,
            protein: 45,
            carbs: 50,
            fat: 20,
            meal: .lunch,
            date: .now
        )

        do {
            try await store.addFoodAwaitingCloud(entry)
            XCTFail("Expected cloudUnavailable")
        } catch let error as FoodLogError {
            XCTAssertEqual(error.localizedDescription.contains("cloud"), true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(
            store.foods.filter { $0.name == "The Founder" }.isEmpty,
            "Failed cloud log must not leave a nutrition entry"
        )
    }

    func testLogSavedMealAwaitingCloudFailsWithoutFirestore() async throws {
        let container = try SyncFitModelContainer.make(inMemory: true)
        let store = FitnessDataStore(context: container.mainContext)
        store.firestore = nil

        let meal = SavedMeal(
            name: "The Founder",
            components: [
                MealComponent(name: "The Founder", calories: 640, protein: 45, carbs: 50, fat: 20)
            ]
        )

        do {
            try await store.logSavedMealAwaitingCloud(meal, as: .dinner)
            XCTFail("Expected cloudUnavailable")
        } catch is FoodLogError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(store.foods.filter { $0.name == "The Founder" }.isEmpty)
    }
}
