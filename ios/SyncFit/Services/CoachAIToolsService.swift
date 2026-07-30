import Foundation
import FirebaseAuth
import FirebaseFunctions

enum CoachAIRoutineGoal: String, CaseIterable, Identifiable {
    case progressiveOverload = "progressive_overload"
    case maintenance = "maintenance"
    case strength = "strength"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .progressiveOverload: return "Progressive overload"
        case .maintenance: return "Maintenance"
        case .strength: return "Strength"
        }
    }

    var subtitle: String {
        switch self {
        case .progressiveOverload: return "Build volume and progress lifts week to week"
        case .maintenance: return "Hold fitness with balanced, sustainable training"
        case .strength: return "Heavier compounds, lower reps, strength focus"
        }
    }
}

enum CoachAIToolsError: LocalizedError {
    case notSignedIn
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in required."
        case .invalidResponse:
            return "Couldn't read the AI response. Please try again."
        case .server(let message):
            return message
        }
    }
}

enum CoachAIToolsService {
    private static let functions = Functions.functions()

    static func generateRoutineDraft(
        clientUserID: String,
        goal: CoachAIRoutineGoal
    ) async throws -> CoachRoutineTemplate {
        guard Auth.auth().currentUser != nil else {
            throw CoachAIToolsError.notSignedIn
        }

        let callable = functions.httpsCallable("generateCoachRoutineDraft")
        let result: HTTPSCallableResult
        do {
            result = try await callable.call([
                "clientUserID": clientUserID,
                "goal": goal.rawValue
            ])
        } catch {
            throw mapFunctionsError(error)
        }

        guard let data = result.data as? [String: Any],
              let templateAny = data["template"] else {
            throw CoachAIToolsError.invalidResponse
        }

        return try decodeRoutineTemplate(templateAny)
    }

    static func generateClientInsights(
        clientUserID: String,
        forceRefresh: Bool = false
    ) async throws -> (insight: String, cached: Bool) {
        guard Auth.auth().currentUser != nil else {
            throw CoachAIToolsError.notSignedIn
        }

        let callable = functions.httpsCallable("generateClientInsights")
        let result: HTTPSCallableResult
        do {
            result = try await callable.call([
                "clientUserID": clientUserID,
                "forceRefresh": forceRefresh
            ])
        } catch {
            throw mapFunctionsError(error)
        }

        guard let data = result.data as? [String: Any],
              let insight = data["insight"] as? String,
              !insight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoachAIToolsError.invalidResponse
        }

        return (insight, (data["cached"] as? Bool) ?? false)
    }

    private static func decodeRoutineTemplate(_ value: Any) throws -> CoachRoutineTemplate {
        let jsonData: Data
        if let data = value as? Data {
            jsonData = data
        } else if JSONSerialization.isValidJSONObject(value) {
            jsonData = try JSONSerialization.data(withJSONObject: value)
        } else {
            throw CoachAIToolsError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: string) {
                    return date
                }
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date value"
            )
        }

        return try decoder.decode(CoachRoutineTemplate.self, from: jsonData)
    }

    private static func mapFunctionsError(_ error: Error) -> Error {
        let nsError = error as NSError
        let message =
            (nsError.userInfo["NSLocalizedDescription"] as? String)
            ?? nsError.localizedDescription
        if nsError.domain == FunctionsErrorDomain {
            return CoachAIToolsError.server(message)
        }
        return error
    }
}
