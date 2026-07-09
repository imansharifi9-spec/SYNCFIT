import Foundation

enum NutritionixService {
    private static let baseURL = "https://trackapi.nutritionix.com/v2"

    static func search(query: String, appID: String, appKey: String) async throws -> [FoodLibraryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains(" and ") || trimmed.split(separator: " ").count >= 4 {
            if let natural = try await naturalLanguageNutrients(query: trimmed, appID: appID, appKey: appKey) {
                return [natural]
            }
        }

        guard let url = URL(string: "\(baseURL)/search/instant") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(appID, forHTTPHeaderField: "x-app-id")
        request.setValue(appKey, forHTTPHeaderField: "x-app-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": trimmed])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(InstantSearchResponse.self, from: data)
        var items: [FoodLibraryItem] = []

        for branded in decoded.branded ?? [] {
            guard let name = branded.food_name, let calories = branded.nf_calories else { continue }
            items.append(
                FoodLibraryItem(
                    name: name,
                    brand: branded.brand_name ?? "Nutritionix",
                    referenceGrams: 1,
                    servingGrams: branded.serving_qty,
                    isPerServing: true,
                    calories: calories,
                    protein: branded.nf_protein ?? 0,
                    carbs: branded.nf_total_carbohydrate ?? 0,
                    fat: branded.nf_total_fat ?? 0
                )
            )
        }

        for common in decoded.common ?? [] {
            guard let name = common.food_name else { continue }
            items.append(
                FoodLibraryItem(
                    name: name,
                    brand: "Nutritionix",
                    calories: 0,
                    protein: 0,
                    carbs: 0,
                    fat: 0
                )
            )
        }

        return Array(items.prefix(25))
    }

    static func lookupBarcode(_ barcode: String, appID: String, appKey: String) async throws -> FoodLibraryItem? {
        guard let url = URL(string: "\(baseURL)/search/item?upc=\(barcode)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(appID, forHTTPHeaderField: "x-app-id")
        request.setValue(appKey, forHTTPHeaderField: "x-app-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(ItemResponse.self, from: data)
        guard let food = decoded.foods?.first else { return nil }
        return food.asLibraryItem(source: "Nutritionix")
    }

    private static func naturalLanguageNutrients(
        query: String,
        appID: String,
        appKey: String
    ) async throws -> FoodLibraryItem? {
        guard let url = URL(string: "\(baseURL)/natural/nutrients") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(appID, forHTTPHeaderField: "x-app-id")
        request.setValue(appKey, forHTTPHeaderField: "x-app-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["query": query])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(NaturalResponse.self, from: data)
        guard let food = decoded.foods?.first else { return nil }
        return food.asLibraryItem(source: "Nutritionix")
    }
}

private struct InstantSearchResponse: Decodable {
    let common: [InstantFood]?
    let branded: [InstantBranded]?
}

private struct InstantFood: Decodable {
    let food_name: String?
}

private struct InstantBranded: Decodable {
    let food_name: String?
    let brand_name: String?
    let serving_qty: Double?
    let nf_calories: Double?
    let nf_protein: Double?
    let nf_total_carbohydrate: Double?
    let nf_total_fat: Double?
}

private struct ItemResponse: Decodable {
    let foods: [NutritionixFood]?
}

private struct NaturalResponse: Decodable {
    let foods: [NutritionixFood]?
}

private struct NutritionixFood: Decodable {
    let food_name: String?
    let brand_name: String?
    let serving_qty: Double?
    let serving_weight_grams: Double?
    let nf_calories: Double?
    let nf_protein: Double?
    let nf_total_carbohydrate: Double?
    let nf_total_fat: Double?

    func asLibraryItem(source: String) -> FoodLibraryItem? {
        guard let name = food_name, let calories = nf_calories else { return nil }
        let grams = serving_weight_grams ?? serving_qty
        return FoodLibraryItem(
            name: name,
            brand: brand_name ?? source,
            referenceGrams: 1,
            servingGrams: grams,
            isPerServing: true,
            calories: calories,
            protein: nf_protein ?? 0,
            carbs: nf_total_carbohydrate ?? 0,
            fat: nf_total_fat ?? 0
        )
    }
}
