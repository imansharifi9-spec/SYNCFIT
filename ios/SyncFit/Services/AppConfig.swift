import Foundation

enum AppConfig {
    /// Injected at build time via `Secrets.xcconfig` → `INFOPLIST_KEY_USDA_API_KEY`.
    /// Get a free key from https://api.data.gov — never exposed to end users in Settings.
    static var usdaApiKey: String {
        let key = (Bundle.main.object(forInfoDictionaryKey: "USDA_API_KEY") as? String) ?? ""
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isFoodSearchEnabled: Bool {
        !usdaApiKey.isEmpty
    }

    static let privacyPolicyURL = URL(string: "https://syncfit.app/privacy")!
    static let termsOfServiceURL = URL(string: "https://syncfit.app/terms")!
}
