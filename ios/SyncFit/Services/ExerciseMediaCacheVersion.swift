import Foundation

/// Shared invalidation token for exercise media caches.
/// Bump when matching / resolution logic changes so session URL cache and
/// thumbnail disk/memory caches invalidate together.
enum ExerciseMediaCacheVersion {
    /// Increment on matching-logic fixes (e.g. Face Pull strict scoring).
    static let current = 4

    static var thumbnailFolderName: String {
        "ExerciseThumbnails_v\(current)"
    }
}
