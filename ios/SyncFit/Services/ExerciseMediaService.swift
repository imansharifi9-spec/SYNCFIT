import Foundation
import FirebaseAuth
import FirebaseFunctions

struct ExerciseMediaResolution: Equatable {
    enum Status: String, Equatable {
        case found
        case notFound = "not_found"
    }

    let status: Status
    let gifURL: URL?
    let matchedName: String?
    let targetMuscles: [String]
    /// Server deploy stamp (`MEDIA_LOGIC_VERSION`) when response came from the callable.
    let mediaLogicVersion: String?

    var hasDemoGIF: Bool { status == .found && gifURL != nil }
}

enum ExerciseMediaService {
    private static let functions = Functions.functions()

    /// Resolve a demo GIF for an exercise name via the `resolveExerciseMedia` callable.
    static func resolve(exerciseName: String) async throws -> ExerciseMediaResolution {
        let trimmed = exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
        ExerciseMediaDiag.log("[ExerciseMedia] Requesting resolveExerciseMedia for exercise=\(trimmed)")

        guard !trimmed.isEmpty else {
            ExerciseMediaDiag.log("[ExerciseMedia] Abort: empty exercise name")
            ExerciseMediaDiag.log("[ExerciseMedia] Resolved gifUrl=nil")
            return ExerciseMediaResolution(
                status: .notFound,
                gifURL: nil,
                matchedName: nil,
                targetMuscles: [],
                mediaLogicVersion: nil
            )
        }

        guard Auth.auth().currentUser != nil else {
            ExerciseMediaDiag.log("[ExerciseMedia] Abort: Auth.auth().currentUser is nil (signed out)")
            ExerciseMediaDiag.log("[ExerciseMedia] Resolved gifUrl=nil")
            return ExerciseMediaResolution(
                status: .notFound,
                gifURL: nil,
                matchedName: nil,
                targetMuscles: [],
                mediaLogicVersion: nil
            )
        }

        let callable = functions.httpsCallable("resolveExerciseMedia")
        let result: HTTPSCallableResult
        do {
            result = try await callable.call(["exerciseName": trimmed])
        } catch {
            ExerciseMediaDiag.log("[ExerciseMedia] Callable error: \(error)")
            if let nsError = error as NSError? {
                ExerciseMediaDiag.log("[ExerciseMedia] Callable NSError domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
            }
            ExerciseMediaDiag.log("[ExerciseMedia] Resolved gifUrl=nil")
            throw error
        }

        ExerciseMediaDiag.log("[ExerciseMedia] Raw response data=\(String(describing: result.data))")

        guard let data = result.data as? [String: Any] else {
            ExerciseMediaDiag.log("[ExerciseMedia] Abort: response data is not a dictionary")
            ExerciseMediaDiag.log("[ExerciseMedia] Resolved gifUrl=nil")
            return ExerciseMediaResolution(
                status: .notFound,
                gifURL: nil,
                matchedName: nil,
                targetMuscles: [],
                mediaLogicVersion: nil
            )
        }

        let statusRaw = (data["status"] as? String) ?? "not_found"
        let status = ExerciseMediaResolution.Status(rawValue: statusRaw) ?? .notFound
        let gifString = data["gifUrl"] as? String
        let gifURL = gifString.flatMap(URL.init(string:))
        let matchedName = data["matchedName"] as? String
        let targetMuscles = (data["targetMuscles"] as? [Any])?.compactMap { $0 as? String } ?? []
        let mediaLogicVersion = data["mediaLogicVersion"] as? String

        let resolved = ExerciseMediaResolution(
            status: status,
            gifURL: status == .found ? gifURL : nil,
            matchedName: matchedName,
            targetMuscles: targetMuscles,
            mediaLogicVersion: mediaLogicVersion
        )
        ExerciseMediaDiag.log("[ExerciseMedia] Resolved gifUrl=\(resolved.gifURL?.absoluteString ?? "nil") status=\(resolved.status.rawValue) matchedName=\(resolved.matchedName ?? "nil") mediaLogicVersion=\(mediaLogicVersion ?? "nil")")
        return resolved
    }
}
