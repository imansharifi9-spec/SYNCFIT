import Foundation

enum OpenFoodFactsService {
    struct BarcodeLookupResult {
        var item: FoodLibraryItem?
        /// Product name from OFF when nutrition data is missing — used for USDA search fallback.
        var fallbackSearchName: String?
    }

    static func lookupBarcode(_ barcode: String) async throws -> BarcodeLookupResult {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(trimmed).json") else {
            return BarcodeLookupResult()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return BarcodeLookupResult()
        }

        let decoded = try JSONDecoder().decode(ProductResponse.self, from: data)
        guard decoded.status == 1, let product = decoded.product else {
            return BarcodeLookupResult()
        }

        let name = resolvedProductName(from: product)
        if let item = mapProduct(product, barcode: trimmed) {
            return BarcodeLookupResult(item: item, fallbackSearchName: name)
        }

        return BarcodeLookupResult(item: nil, fallbackSearchName: name)
    }

    private static func resolvedProductName(from product: OFFProduct) -> String? {
        let candidates = [
            product.product_name,
            product.generic_name,
            product.brands
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func mapProduct(_ product: OFFProduct, barcode: String) -> FoodLibraryItem? {
        let name = resolvedProductName(from: product) ?? "Scanned food"
        let nutriments = product.nutriments

        if let servingQuantity = product.serving_quantity, servingQuantity > 0,
           let caloriesPerServing = nutriments?.energy_kcal_serving ?? nutriments?.energy_kcal,
           caloriesPerServing > 0 {
            return FoodLibraryItem(
                name: name,
                brand: product.brands?.trimmingCharacters(in: .whitespacesAndNewlines),
                referenceGrams: servingQuantity,
                servingGrams: servingQuantity,
                isPerServing: true,
                calories: caloriesPerServing,
                protein: nutriments?.proteins_serving ?? nutriments?.proteins ?? 0,
                carbs: nutriments?.carbohydrates_serving ?? nutriments?.carbohydrates ?? 0,
                fat: nutriments?.fat_serving ?? nutriments?.fat ?? 0
            )
        }

        let calories = nutriments?.energy_kcal_100g ?? nutriments?.energy_kcal ?? 0
        guard calories > 0 else { return nil }

        return FoodLibraryItem(
            name: name,
            brand: product.brands?.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceGrams: 100,
            servingGrams: product.serving_quantity,
            isPerServing: false,
            calories: calories,
            protein: nutriments?.proteins_100g ?? nutriments?.proteins ?? 0,
            carbs: nutriments?.carbohydrates_100g ?? nutriments?.carbohydrates ?? 0,
            fat: nutriments?.fat_100g ?? nutriments?.fat ?? 0
        )
    }
}

private struct ProductResponse: Decodable {
    let status: Int?
    let product: OFFProduct?
}

private struct OFFProduct: Decodable {
    let product_name: String?
    let generic_name: String?
    let brands: String?
    let serving_quantity: Double?
    let nutriments: OFFNutriments?
}

private struct OFFNutriments: Decodable {
    let energy_kcal: Double?
    let energy_kcal_100g: Double?
    let energy_kcal_serving: Double?
    let proteins: Double?
    let proteins_100g: Double?
    let proteins_serving: Double?
    let carbohydrates: Double?
    let carbohydrates_100g: Double?
    let carbohydrates_serving: Double?
    let fat: Double?
    let fat_100g: Double?
    let fat_serving: Double?
}
