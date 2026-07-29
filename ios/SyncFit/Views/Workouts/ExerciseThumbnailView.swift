import SwiftUI

/// Static first-frame exercise thumbnail for scrolling lists.
/// Animated GIFs stay in `ExerciseDemoGIFView` (Edit Exercise only).
struct ExerciseThumbnailView: View {
    let exerciseName: String
    let muscleGroup: String
    var size: CGFloat = 52

    @State private var image: UIImage?
    @State private var loadFailed = false

    private var cornerRadius: CGFloat { size >= 60 ? 14 : 10 }
    private var cacheKey: String {
        ExerciseDemoGIFSessionCache.normalizedKey(exerciseName)
    }

    var body: some View {
        ZStack {
            // Always reserve the icon footprint — never a blank gap while loading / on miss.
            ExerciseIllustrationView(
                exerciseName: exerciseName,
                muscleGroup: muscleGroup,
                style: .thumbnail
            )
            .opacity(image == nil ? 1 : 0)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                MuscleGroupArt.accentColor(
                                    for: MuscleGroupArt.primaryGroup(
                                        for: muscleGroup,
                                        exerciseName: exerciseName
                                    )
                                ).opacity(0.3),
                                lineWidth: 1
                            )
                    }
                    .transition(.opacity)
            }

            if image == nil && !loadFailed {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: cacheKey) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        guard !cacheKey.isEmpty else {
            loadFailed = true
            image = nil
            return
        }

        if let cached = ExerciseThumbnailCache.cachedImage(for: exerciseName) {
            image = cached
            loadFailed = false
            return
        }

        loadFailed = false
        let loaded = await ExerciseThumbnailCache.thumbnail(for: exerciseName)
        // Drop stale results if the row was recycled for another exercise.
        guard ExerciseDemoGIFSessionCache.normalizedKey(exerciseName) == cacheKey else { return }

        if let loaded {
            image = loaded
            loadFailed = false
        } else {
            image = nil
            loadFailed = true
        }
    }
}
