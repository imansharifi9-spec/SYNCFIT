import Foundation
import ImageIO
import UIKit

/// Loads static first-frame thumbnails from ExerciseDB GIF URLs.
/// Reuses `ExerciseDemoGIFSessionCache` / `ExerciseMediaService` for URL resolution —
/// does not call the Cloud Function separately from the demo GIF path.
enum ExerciseThumbnailCache {
    private static let memory = NSCache<NSString, UIImage>()
    private static let lock = NSLock()
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]
    private static let maxConcurrentDownloads = 4
    private static let downloadSemaphore = AsyncSemaphore(value: maxConcurrentDownloads)
    private static var loadedVersion: Int = -1

    private static var folderName: String {
        ExerciseMediaCacheVersion.thumbnailFolderName
    }

    static func configure() {
        memory.countLimit = 120
        memory.totalCostLimit = 24 * 1024 * 1024
        ensureCurrentVersion()
    }

    private static func ensureCurrentVersion() {
        lock.lock()
        defer { lock.unlock() }
        guard loadedVersion != ExerciseMediaCacheVersion.current else { return }
        memory.removeAllObjects()
        inFlight.removeAll()
        loadedVersion = ExerciseMediaCacheVersion.current
        ExerciseMediaDiag.log(
            "[ExerciseMedia] thumbnail cache invalidated → folder=\(folderName) version=\(ExerciseMediaCacheVersion.current)"
        )
    }

    static func cachedImage(for exerciseName: String) -> UIImage? {
        let key = ExerciseDemoGIFSessionCache.normalizedKey(exerciseName)
        guard !key.isEmpty else { return nil }
        if let mem = memory.object(forKey: key as NSString) {
            return mem
        }
        if let disk = loadFromDisk(key: key) {
            memory.setObject(disk, forKey: key as NSString, cost: disk.approximateCost)
            return disk
        }
        return nil
    }

    /// Resolve GIF URL (shared cache), download once, extract first frame, cache.
    static func thumbnail(for exerciseName: String) async -> UIImage? {
        configure()
        let key = ExerciseDemoGIFSessionCache.normalizedKey(exerciseName)
        guard !key.isEmpty else { return nil }

        if let cached = cachedImage(for: exerciseName) {
            if ExerciseDemoGIFSessionCache.normalizedKey(exerciseName) == "face pull" {
                ExerciseMediaDiag.log("[ExerciseMedia] FacePull thumbnail: source=client_disk_or_memory_thumbnail (skipped resolveExerciseMedia)")
            }
            return cached
        }

        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            await loadAndExtract(exerciseName: exerciseName, key: key)
        }
        inFlight[key] = task
        lock.unlock()

        let image = await task.value

        lock.lock()
        inFlight[key] = nil
        lock.unlock()
        return image
    }

    private static func loadAndExtract(exerciseName: String, key: String) async -> UIImage? {
        if let cached = cachedImage(for: exerciseName) {
            return cached
        }

        if key == "face pull" {
            ExerciseMediaDiag.log("[ExerciseMedia] FacePull thumbnail: resolving URL via ExerciseDemoGIFSessionCache → may call server")
        }

        let mediaEntry = await ExerciseDemoGIFSessionCache.resolve(exerciseName: exerciseName) { name in
            do {
                let result = try await ExerciseMediaService.resolve(exerciseName: name)
                if let url = result.gifURL, result.hasDemoGIF {
                    return .loaded(url)
                }
                return .unavailable
            } catch {
                return .unavailable
            }
        }

        guard case .loaded(let gifURL) = mediaEntry else {
            if key == "face pull" {
                ExerciseMediaDiag.log("[ExerciseMedia] FacePull thumbnail: no gifUrl after resolve")
            }
            return nil
        }

        if key == "face pull" {
            ExerciseMediaDiag.log("[ExerciseMedia] FacePull thumbnail: downloading gifUrl=\(gifURL.absoluteString)")
        }

        await downloadSemaphore.wait()
        // Re-check cache after waiting in the download queue.
        if let cached = cachedImage(for: exerciseName) {
            await downloadSemaphore.signal()
            return cached
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: gifURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                await downloadSemaphore.signal()
                return nil
            }
            guard let image = firstFrameImage(from: data) else {
                await downloadSemaphore.signal()
                return nil
            }

            memory.setObject(image, forKey: key as NSString, cost: image.approximateCost)
            saveToDisk(image: image, key: key)
            await downloadSemaphore.signal()
            return image
        } catch {
            await downloadSemaphore.signal()
            return nil
        }
    }

    /// ImageIO first frame only — never animates, suitable for list rows.
    static func firstFrameImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Disk

    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func diskURL(key: String) -> URL? {
        directoryURL?.appendingPathComponent("\(key).jpg")
    }

    private static func loadFromDisk(key: String) -> UIImage? {
        guard let url = diskURL(key: key),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else {
            return nil
        }
        return image
    }

    private static func saveToDisk(image: UIImage, key: String) {
        guard let url = diskURL(key: key),
              let data = image.jpegData(compressionQuality: 0.82)
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

private extension UIImage {
    var approximateCost: Int {
        guard let cgImage else { return 64 * 1024 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// Lightweight async semaphore to cap concurrent GIF downloads in scrolling lists.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = value
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let first = waiters.first {
            waiters.removeFirst()
            first.resume()
        } else {
            value += 1
        }
    }
}
