import Foundation

struct FoodLibraryItem: Identifiable, Hashable {
    let id: UUID
    var fdcId: Int?
    var name: String
    var brand: String?
    /// Reference amount that the macro values are defined for (default: 100g).
    var referenceGrams: Double
    /// Optional “one serving” weight in grams (useful for branded items like shakes/yogurts).
    var servingGrams: Double?
    /// Branded USDA items store label macros per serving (MFP-style).
    var isPerServing: Bool
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double

    init(
        id: UUID = UUID(),
        fdcId: Int? = nil,
        name: String,
        brand: String? = nil,
        referenceGrams: Double = 100,
        servingGrams: Double? = nil,
        isPerServing: Bool = false,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) {
        self.id = id
        self.fdcId = fdcId
        self.name = name
        self.brand = brand
        self.referenceGrams = referenceGrams
        self.servingGrams = servingGrams
        self.isPerServing = isPerServing
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    func scaled(to grams: Double) -> (calories: Int, protein: Int, carbs: Int, fat: Int) {
        let factor = grams / max(referenceGrams, 1)
        return (
            calories: Int((calories * factor).rounded()),
            protein: Int((protein * factor).rounded()),
            carbs: Int((carbs * factor).rounded()),
            fat: Int((fat * factor).rounded())
        )
    }

    func scaled(servings: Double) -> (calories: Int, protein: Int, carbs: Int, fat: Int)? {
        guard let servingGrams, servingGrams > 0 else { return nil }
        return scaled(to: servings * servingGrams)
    }

    func matchingServingLabel(
        calories: Int,
        protein: Int,
        carbs: Int,
        fat: Int
    ) -> String? {
        if isPerServing, let perServing = scaled(servings: 1),
           macrosMatch(perServing, calories: calories, protein: protein, carbs: carbs, fat: fat) {
            return "1 serving"
        }

        let gramCandidates: [Double] = {
            var values: [Double] = [28.3495, 50, 85, 100, 113, 150, 170, 200, 240]
            if let servingGrams, servingGrams > 0 {
                values.insert(servingGrams, at: 0)
            }
            return values
        }()

        for grams in gramCandidates {
            let scaled = scaled(to: grams)
            guard macrosMatch(scaled, calories: calories, protein: protein, carbs: carbs, fat: fat) else {
                continue
            }
            if grams == 28.3495 { return "1 oz" }
            if grams == 240 { return "1 cup" }
            let rounded = SyncFitFormat.round(grams)
            return rounded == 1 ? "1g" : "\(SyncFitFormat.decimal(rounded))g"
        }
        return nil
    }

    private func macrosMatch(
        _ scaled: (calories: Int, protein: Int, carbs: Int, fat: Int),
        calories: Int,
        protein: Int,
        carbs: Int,
        fat: Int
    ) -> Bool {
        scaled.calories == calories
            && scaled.protein == protein
            && scaled.carbs == carbs
            && scaled.fat == fat
    }
}

enum FoodLibrary {
    static let items: [FoodLibraryItem] = [
        FoodLibraryItem(name: "Chicken breast, cooked", calories: 165, protein: 31, carbs: 0, fat: 3.6),
        FoodLibraryItem(name: "Chicken thigh, cooked", calories: 209, protein: 26, carbs: 0, fat: 10.9),
        FoodLibraryItem(name: "Ground beef 90% lean, cooked", calories: 217, protein: 26, carbs: 0, fat: 11.8),
        FoodLibraryItem(name: "Salmon, cooked", calories: 206, protein: 22, carbs: 0, fat: 12),
        FoodLibraryItem(name: "Tuna, canned in water", calories: 116, protein: 26, carbs: 0, fat: 1),
        FoodLibraryItem(name: "Egg, whole", calories: 143, protein: 13, carbs: 1.1, fat: 9.5),
        FoodLibraryItem(name: "Egg whites", calories: 52, protein: 11, carbs: 0.7, fat: 0.2),

        FoodLibraryItem(name: "White rice, cooked", calories: 130, protein: 2.7, carbs: 28.2, fat: 0.3),
        FoodLibraryItem(name: "Brown rice, cooked", calories: 123, protein: 2.7, carbs: 25.6, fat: 1),
        FoodLibraryItem(name: "Oats, dry", calories: 389, protein: 16.9, carbs: 66.3, fat: 6.9),
        FoodLibraryItem(name: "Quinoa, cooked", calories: 120, protein: 4.4, carbs: 21.3, fat: 1.9),
        FoodLibraryItem(name: "Pasta, cooked", calories: 131, protein: 5, carbs: 25, fat: 1.1),
        FoodLibraryItem(name: "Potato, baked", calories: 93, protein: 2.5, carbs: 21.2, fat: 0.1),

        FoodLibraryItem(name: "Greek yogurt, nonfat plain", calories: 59, protein: 10.3, carbs: 3.6, fat: 0.4),
        FoodLibraryItem(name: "Milk, 2%", calories: 50, protein: 3.4, carbs: 4.9, fat: 2),
        FoodLibraryItem(name: "Cheddar cheese", calories: 403, protein: 25, carbs: 1.3, fat: 33),

        FoodLibraryItem(name: "Banana", calories: 89, protein: 1.1, carbs: 22.8, fat: 0.3),
        FoodLibraryItem(name: "Apple", calories: 52, protein: 0.3, carbs: 13.8, fat: 0.2),
        FoodLibraryItem(name: "Blueberries", calories: 57, protein: 0.7, carbs: 14.5, fat: 0.3),

        FoodLibraryItem(name: "Broccoli", calories: 34, protein: 2.8, carbs: 6.6, fat: 0.4),
        FoodLibraryItem(name: "Spinach", calories: 23, protein: 2.9, carbs: 3.6, fat: 0.4),
        FoodLibraryItem(name: "Avocado", calories: 160, protein: 2, carbs: 8.5, fat: 14.7),

        FoodLibraryItem(name: "Olive oil", calories: 884, protein: 0, carbs: 0, fat: 100),
        FoodLibraryItem(name: "Peanut butter", calories: 588, protein: 25, carbs: 20, fat: 50),
        FoodLibraryItem(name: "Almonds", calories: 579, protein: 21.2, carbs: 21.7, fat: 49.9)
    ]
}

