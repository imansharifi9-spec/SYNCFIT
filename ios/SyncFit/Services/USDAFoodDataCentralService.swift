import Foundation

enum USDAFoodDataCentralService {
    struct FoodNutrient: Hashable, Decodable {
        let nutrientId: Int?
        let nutrientName: String?
        let unitName: String?
        let value: Double?
    }

    struct SearchResponse: Decodable {
        let foods: [Food]

        struct Food: Decodable {
            let fdcId: Int
            let dataType: String?
            let description: String
            let brandOwner: String?
            let servingSize: Double?
            let servingSizeUnit: String?
            let householdServingFullText: String?
            let foodNutrients: [FoodNutrient]?
        }
    }

    struct DetailResponse: Decodable {
        let fdcId: Int
        let dataType: String?
        let description: String
        let brandOwner: String?
        let servingSize: Double?
        let servingSizeUnit: String?
        let householdServingFullText: String?
        let foodNutrients: [FoodNutrient]?
        let labelNutrients: LabelNutrients?

        struct LabelNutrients: Decodable {
            let calories: NutrientValue?
            let protein: NutrientValue?
            let carbohydrates: NutrientValue?
            let fat: NutrientValue?

            struct NutrientValue: Decodable {
                let value: Double?
            }
        }
    }

    static func searchFoods(query: String, apiKey: String, pageSize: Int = 50) async throws -> [FoodLibraryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "requireAllWords", value: "true"),
            URLQueryItem(name: "dataType", value: "Branded"),
            URLQueryItem(name: "dataType", value: "Foundation"),
            URLQueryItem(name: "dataType", value: "SR Legacy")
        ]

        let data = try await performRequest(url: components.url!)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.foods.compactMap { mapFood($0) }
    }

    static func fetchFood(fdcId: Int, apiKey: String) async throws -> FoodLibraryItem? {
        var components = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/food/\(fdcId)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let data = try await performRequest(url: components.url!)
        let food = try JSONDecoder().decode(DetailResponse.self, from: data)
        return mapDetailFood(food)
    }

    private static func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "USDAFoodDataCentralService", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "USDA request failed (\(http.statusCode))."
            ])
        }
        return data
    }

    private static func mapFood(_ food: SearchResponse.Food) -> FoodLibraryItem? {
        mapToLibraryItem(
            fdcId: food.fdcId,
            dataType: food.dataType,
            description: food.description,
            brandOwner: food.brandOwner,
            servingSize: food.servingSize,
            servingSizeUnit: food.servingSizeUnit,
            nutrients: food.foodNutrients ?? [],
            labelNutrients: nil
        )
    }

    private static func mapDetailFood(_ food: DetailResponse) -> FoodLibraryItem? {
        mapToLibraryItem(
            fdcId: food.fdcId,
            dataType: food.dataType,
            description: food.description,
            brandOwner: food.brandOwner,
            servingSize: food.servingSize,
            servingSizeUnit: food.servingSizeUnit,
            nutrients: food.foodNutrients ?? [],
            labelNutrients: food.labelNutrients
        )
    }

    private static func mapToLibraryItem(
        fdcId: Int,
        dataType: String?,
        description: String,
        brandOwner: String?,
        servingSize: Double?,
        servingSizeUnit: String?,
        nutrients: [FoodNutrient],
        labelNutrients: DetailResponse.LabelNutrients?
    ) -> FoodLibraryItem? {
        let cleanName = cleanDescription(description)
        guard !cleanName.isEmpty else { return nil }

        let isBranded = (dataType ?? "").localizedCaseInsensitiveContains("branded")
        let serving = servingGrams(from: servingSize, unit: servingSizeUnit)

        if isBranded, let serving, serving > 0 {
            if let label = labelNutrients,
               let calories = label.calories?.value,
               let protein = label.protein?.value,
               let carbs = label.carbohydrates?.value,
               let fat = label.fat?.value {
                return FoodLibraryItem(
                    id: stableID(fdcId: fdcId),
                    fdcId: fdcId,
                    name: cleanName,
                    brand: brandOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
                    referenceGrams: serving,
                    servingGrams: serving,
                    isPerServing: true,
                    calories: calories,
                    protein: protein,
                    carbs: carbs,
                    fat: fat
                )
            }

            if let macros = macrosFromNutrients(nutrients, perServing: true) {
                return FoodLibraryItem(
                    id: stableID(fdcId: fdcId),
                    fdcId: fdcId,
                    name: cleanName,
                    brand: brandOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
                    referenceGrams: serving,
                    servingGrams: serving,
                    isPerServing: true,
                    calories: macros.calories,
                    protein: macros.protein,
                    carbs: macros.carbs,
                    fat: macros.fat
                )
            }
        }

        guard let macros = macrosFromNutrients(nutrients, perServing: false) else { return nil }

        return FoodLibraryItem(
            id: stableID(fdcId: fdcId),
            fdcId: fdcId,
            name: cleanName,
            brand: brandOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceGrams: 100,
            servingGrams: serving,
            isPerServing: false,
            calories: macros.calories,
            protein: macros.protein,
            carbs: macros.carbs,
            fat: macros.fat
        )
    }

    private static func macrosFromNutrients(
        _ nutrients: [FoodNutrient],
        perServing: Bool
    ) -> (calories: Double, protein: Double, carbs: Double, fat: Double)? {
        func byID(_ id: Int) -> Double? {
            nutrients.first(where: { $0.nutrientId == id })?.value
        }

        func byName(_ name: String) -> Double? {
            nutrients.first(where: { ($0.nutrientName ?? "").caseInsensitiveCompare(name) == .orderedSame })?.value
        }

        let caloriesKcal: Double? = {
            if let kcal = byID(1008) ?? byName("Energy") {
                return kcal
            }
            if let kj = nutrients.first(where: {
                ($0.nutrientName ?? "").localizedCaseInsensitiveContains("energy")
                    && ($0.unitName ?? "").uppercased() == "KJ"
            })?.value {
                return kj / 4.184
            }
            return nil
        }()

        let protein = byID(1003) ?? byName("Protein")
        let carbs = byID(1005) ?? byName("Carbohydrate, by difference") ?? byName("Carbohydrate")
        let fat = byID(1004) ?? byName("Total lipid (fat)") ?? byName("Fat, total lipid (fat)")

        guard let caloriesKcal, let protein, let carbs, let fat else { return nil }

        if perServing {
            return (caloriesKcal, protein, carbs, fat)
        }

        return (caloriesKcal, protein, carbs, fat)
    }

    private static func stableID(fdcId: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8((fdcId >> 24) & 0xFF)
        bytes[1] = UInt8((fdcId >> 16) & 0xFF)
        bytes[2] = UInt8((fdcId >> 8) & 0xFF)
        bytes[3] = UInt8(fdcId & 0xFF)
        bytes[4] = 0xFD
        bytes[5] = 0xC0
        bytes[6] = 0x00
        bytes[7] = 0x01
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func cleanDescription(_ raw: String) -> String {
        displayName(from: raw)
    }

    /// Shortens verbose USDA names (e.g. "Chicken, broilers or fryers, breast, …") to 2–3 readable words.
    static func displayName(from raw: String) -> String {
        let segments = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        }

        let filler = Set([
            "broilers", "fryers", "or", "and", "with", "without", "nfs", "ns",
            "meat", "only", "all", "types", "prepared", "as", "to", "the", "a", "an",
            "raw", "cooked", "fresh", "frozen", "canned", "dry", "moist"
        ])

        var words: [String] = []

        for segment in segments.prefix(4) {
            for token in segment.split(whereSeparator: { $0.isWhitespace }) {
                let word = String(token).lowercased()
                guard word.count > 1, !filler.contains(word) else { continue }

                let formatted = String(token).capitalized
                if words.last?.caseInsensitiveCompare(formatted) == .orderedSame { continue }
                words.append(formatted)
                if words.count >= 3 { break }
            }
            if words.count >= 2 { break }
        }

        if words.isEmpty {
            return segments[0].capitalized
        }

        return words.prefix(3).joined(separator: " ")
    }

    private static func servingGrams(from size: Double?, unit: String?) -> Double? {
        guard let size, size > 0 else { return nil }
        let u = unit?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "G"
        switch u {
        case "G", "GRM", "GM":
            return size
        case "OZ", "ONZ":
            return size * 28.3495
        case "ML", "MLT":
            return size
        default:
            return nil
        }
    }
}
