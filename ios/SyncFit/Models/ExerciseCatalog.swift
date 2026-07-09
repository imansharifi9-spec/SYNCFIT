import Foundation
import UIKit

enum ExerciseCatalog {
    /// Converts an exercise name to the image-pack filename slug.
    /// Example: "Lateral Raise" -> "lateral_raise", "Push-Up" -> "push_up"
    static func slug(for exerciseName: String) -> String {
        exerciseName
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    static func imageAssetName(for exerciseName: String) -> String? {
        let assetName = "exercise_\(slug(for: exerciseName))"
        return UIImage(named: assetName) != nil ? assetName : nil
    }

    static func hasBundledImage(for exerciseName: String) -> Bool {
        imageAssetName(for: exerciseName) != nil
    }

    /// Every library exercise and the PNG filename to use in ExerciseImagePack/.
    static var packFilenames: [(exercise: String, filename: String)] {
        ExerciseLibrary.exercises.map { exercise in
            (exercise.name, "\(slug(for: exercise.name)).png")
        }
    }
}
