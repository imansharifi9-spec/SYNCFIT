import SwiftUI
import WebKit

/// Session cache so Form/List row recreation does not re-hit the network or
/// snap back to a loading skeleton for an exercise we already resolved.
///
/// Invalidated whenever `ExerciseMediaCacheVersion.current` changes (shared with
/// thumbnail disk cache) so matching-logic fixes don't leave stale gifUrls.
enum ExerciseDemoGIFSessionCache {
    enum Entry: Equatable {
        case loaded(URL)
        case unavailable
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var inFlight: [String: Task<Entry, Never>] = [:]
    private static var loadedVersion: Int = -1

    private static func ensureCurrentVersionLocked() {
        guard loadedVersion != ExerciseMediaCacheVersion.current else { return }
        entries.removeAll()
        inFlight.removeAll()
        loadedVersion = ExerciseMediaCacheVersion.current
        ExerciseMediaDiag.log(
            "[ExerciseMedia] session cache invalidated → version=\(ExerciseMediaCacheVersion.current)"
        )
    }

    static func entry(for exerciseName: String) -> Entry? {
        let key = normalizedKey(exerciseName)
        lock.lock()
        defer { lock.unlock() }
        ensureCurrentVersionLocked()
        return entries[key]
    }

    /// Returns a cached entry, or awaits a single shared in-flight resolve for this name.
    static func resolve(
        exerciseName: String,
        fetch: @escaping (String) async -> Entry
    ) async -> Entry {
        let key = normalizedKey(exerciseName)
        lock.lock()
        ensureCurrentVersionLocked()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<Entry, Never> {
            await fetch(exerciseName)
        }
        inFlight[key] = task
        lock.unlock()

        let entry = await task.value

        lock.lock()
        ensureCurrentVersionLocked()
        entries[key] = entry
        inFlight[key] = nil
        lock.unlock()
        return entry
    }

    static func normalizedKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Drop a single exercise (e.g. known-bad Face Pull) without bumping global version.
    static func invalidate(exerciseName: String) {
        let key = normalizedKey(exerciseName)
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)
    }

    static func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        inFlight.removeAll()
        loadedVersion = -1
    }

    #if DEBUG
    static func resetForTesting() {
        resetAll()
    }
    #endif
}

/// Animated ExerciseDB demo GIF.
///
/// SwiftUI `AsyncImage` / `UIImage` only shows the **first frame** of a GIF — it does not animate.
/// This view loads the GIF in a lightweight `WKWebView` so the demo actually plays.
struct ExerciseDemoGIFView: View {
    let exerciseName: String
    let muscleGroup: String

    @State private var phase: Phase
    /// Last exercise name we successfully finished resolving for (guards same-name re-entry).
    @State private var resolvedForName: String?

    private enum Phase: Equatable {
        case loading
        case loaded(URL)
        case unavailable

        init(cacheEntry: ExerciseDemoGIFSessionCache.Entry) {
            switch cacheEntry {
            case .loaded(let url): self = .loaded(url)
            case .unavailable: self = .unavailable
            }
        }
    }

    /// Native GIF source is ~180p — keep the frame near that size to avoid upscaling blur.
    private let displaySize: CGFloat = 180
    private var cardHeight: CGFloat { displaySize + 24 }

    init(exerciseName: String, muscleGroup: String) {
        self.exerciseName = exerciseName
        self.muscleGroup = muscleGroup
        // Seed from session cache so Form row recreation does not flash .loading.
        if let cached = ExerciseDemoGIFSessionCache.entry(for: exerciseName) {
            _phase = State(initialValue: Phase(cacheEntry: cached))
            _resolvedForName = State(
                initialValue: ExerciseDemoGIFSessionCache.normalizedKey(exerciseName)
            )
        } else {
            _phase = State(initialValue: .loading)
            _resolvedForName = State(initialValue: nil)
        }
    }

    var body: some View {
        // Fixed-height container keeps Form/List row geometry stable across phase
        // changes (structural skeleton→GIF swaps were recreating this view in a loop).
        ZStack {
            switch phase {
            case .loading:
                skeleton
            case .loaded(let url):
                gifCard(url: url)
            case .unavailable:
                fallback
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: cardHeight)
        .task(id: ExerciseDemoGIFSessionCache.normalizedKey(exerciseName)) {
            await resolveMedia()
        }
    }

    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(height: cardHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            }
            .overlay {
                ProgressView()
                    .tint(SyncFitTheme.accentBright.opacity(0.85))
            }
            .redacted(reason: .placeholder)
    }

    private func gifCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AnimatedGIFWebView(url: url)
                .frame(width: displaySize, height: displaySize)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(MuscleGroupArt.accentColor(for: muscleGroup).opacity(0.28), lineWidth: 1)
                }

            Text("Demo · ExerciseDB")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private var fallback: some View {
        HStack(spacing: 14) {
            ExerciseIllustrationView(
                exerciseName: exerciseName,
                muscleGroup: muscleGroup,
                style: .inline
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("No demo available")
                    .font(.subheadline.weight(.semibold))
                Text("Form preview isn’t in the library for this movement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minHeight: cardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    @MainActor
    private func resolveMedia() async {
        let key = ExerciseDemoGIFSessionCache.normalizedKey(exerciseName)
        let isFacePull = key == "face pull"
        guard !key.isEmpty else {
            phase = .unavailable
            resolvedForName = key
            return
        }

        // Same-name re-entry after we already finished — do not reset to loading or re-fetch.
        if resolvedForName == key {
            switch phase {
            case .loaded(let url):
                ExerciseMediaDiag.log("[ExerciseMedia] source=client_view_state exercise=\(exerciseName) gifUrl=\(url.absoluteString)")
                ExerciseMediaDiag.log("[ExerciseMedia] resolveMedia() skip — already resolved for \(exerciseName)")
                return
            case .unavailable:
                ExerciseMediaDiag.log("[ExerciseMedia] source=client_view_state exercise=\(exerciseName) gifUrl=nil")
                ExerciseMediaDiag.log("[ExerciseMedia] resolveMedia() skip — already resolved for \(exerciseName)")
                return
            case .loading:
                break
            }
        }

        if let cached = ExerciseDemoGIFSessionCache.entry(for: exerciseName) {
            switch cached {
            case .loaded(let url):
                ExerciseMediaDiag.log("[ExerciseMedia] source=client_session_cache exercise=\(exerciseName) gifUrl=\(url.absoluteString)")
            case .unavailable:
                ExerciseMediaDiag.log("[ExerciseMedia] source=client_session_cache exercise=\(exerciseName) gifUrl=nil (unavailable)")
            }
            if isFacePull {
                ExerciseMediaDiag.log("[ExerciseMedia] FacePull path: served from CLIENT session cache (did NOT call resolveExerciseMedia / Firestore)")
            }
            phase = Phase(cacheEntry: cached)
            resolvedForName = key
            return
        }

        // Only show skeleton when resolving a NEW name (not a same-name re-fire).
        if resolvedForName != key {
            phase = .loading
        }

        ExerciseMediaDiag.log("[ExerciseMedia] resolveMedia() started for exercise=\(exerciseName) muscleGroup=\(muscleGroup)")
        if isFacePull {
            ExerciseMediaDiag.log("[ExerciseMedia] FacePull path: no client session cache — will call resolveExerciseMedia (server may use Firestore cache or fresh API)")
        }

        let entry = await ExerciseDemoGIFSessionCache.resolve(exerciseName: exerciseName) { name in
            do {
                let result = try await ExerciseMediaService.resolve(exerciseName: name)
                if let url = result.gifURL, result.hasDemoGIF {
                    ExerciseMediaDiag.log("[ExerciseMedia] source=server_callable exercise=\(name) gifUrl=\(url.absoluteString) matchedName=\(result.matchedName ?? "nil") status=\(result.status.rawValue) mediaLogicVersion=\(result.mediaLogicVersion ?? "nil")")
                    return .loaded(url)
                }
                ExerciseMediaDiag.log("[ExerciseMedia] source=server_callable exercise=\(name) gifUrl=nil matchedName=\(result.matchedName ?? "nil") status=\(result.status.rawValue) mediaLogicVersion=\(result.mediaLogicVersion ?? "nil")")
                return .unavailable
            } catch {
                ExerciseMediaDiag.log("[ExerciseMedia] resolveMedia() → catch error=\(error)")
                return .unavailable
            }
        }

        // Drop stale results if the user edited the name while we were in flight.
        guard ExerciseDemoGIFSessionCache.normalizedKey(exerciseName) == key else { return }

        phase = Phase(cacheEntry: entry)
        resolvedForName = key
        switch entry {
        case .loaded(let url):
            ExerciseMediaDiag.log("[ExerciseMedia] resolveMedia() → loaded url=\(url.absoluteString)")
            if isFacePull {
                ExerciseMediaDiag.log("[ExerciseMedia] FacePull final gifUrl=\(url.absoluteString)")
            }
        case .unavailable:
            ExerciseMediaDiag.log("[ExerciseMedia] resolveMedia() → unavailable (no gifUrl / not found)")
            if isFacePull {
                ExerciseMediaDiag.log("[ExerciseMedia] FacePull final gifUrl=nil")
            }
        }
    }
}

/// WKWebView wrapper that plays animated GIFs (unlike AsyncImage/UIImage).
struct AnimatedGIFWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        ExerciseMediaDiag.logGIF("[AnimatedGIFWebView] load start url=\(url.absoluteString)")

        // Present at intrinsic ~180px with light smoothing; avoid CSS scale-up.
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <style>
            html, body {
              margin: 0; padding: 0;
              width: 100%; height: 100%;
              background: transparent;
              display: flex; align-items: center; justify-content: center;
              overflow: hidden;
            }
            img {
              width: 180px;
              height: 180px;
              object-fit: contain;
              image-rendering: auto;
              border-radius: 12px;
              background: #121417;
            }
          </style>
        </head>
        <body>
          <img src="\(url.absoluteString)" alt="Exercise demo" />
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            ExerciseMediaDiag.logGIF("[AnimatedGIFWebView] didFailProvisionalNavigation error=\(error) url=\(loadedURL?.absoluteString ?? "nil")")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            ExerciseMediaDiag.logGIF("[AnimatedGIFWebView] didFail navigation error=\(error) url=\(loadedURL?.absoluteString ?? "nil")")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ExerciseMediaDiag.logGIF("[AnimatedGIFWebView] didFinish url=\(loadedURL?.absoluteString ?? "nil")")
        }
    }
}
