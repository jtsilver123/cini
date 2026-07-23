import SwiftUI

/// Poster/backdrop image view backed by a shared URLCache sized for a
/// poster-forward app. Disk-cached so lists scroll warm offline.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Show the loading pulse while a URL is fetching. On for posters/backdrops;
    /// off for avatars, where the initials placeholder is the better "loading"
    /// cue (it shows who it is) than a gray pulse.
    var showsLoadingPulse: Bool = true
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: UIImage?
    /// Which URL `loaded` belongs to — a recycled cell keeps the old @State
    /// for a frame before `.task` resets it, so we must ignore an image that
    /// belongs to the previous URL when deciding what to show.
    @State private var loadedURL: URL?
    /// The fetch finished with no image (or there's no URL). Lets us show the
    /// app's loading pulse WHILE a poster is in flight, but fall back to the
    /// caller's static placeholder (film icon, etc.) when there's nothing to load.
    @State private var failed = false

    /// What to render THIS body evaluation. A synchronous memory-cache hit is
    /// resolved here — before `.task` even runs — so a poster already decoded
    /// in memory (scrolling back over content you just saw) renders on the
    /// first frame with NO skeleton flash.
    private var displayImage: UIImage? {
        if let loaded, loadedURL == url { return loaded }
        if let url, let cached = ImageLoader.shared.cachedImage(for: url) { return cached }
        return nil
    }

    var body: some View {
        Group {
            if let displayImage {
                content(Image(uiImage: displayImage))
            } else if url != nil && !failed && showsLoadingPulse {
                // Loading: an OPAQUE surface base (so it's never see-through —
                // Theme.fill is only 7% white) with the app-wide pulse as a
                // sheen on top, so a poster mid-fetch reads as "loading"
                // everywhere — never a transparent or dead blank box.
                Rectangle().fill(Theme.surface2)
                    .overlay(Rectangle().fill(Theme.fill).modifier(SkeletonPulse()))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            failed = false
            guard let url else { loaded = nil; loadedURL = nil; return }
            // Warm hit already shown by displayImage — nothing async to do.
            if let cached = ImageLoader.shared.cachedImage(for: url) {
                loaded = cached; loadedURL = url
                return
            }
            // Cold: clear any stale image so the pulse (not the previous
            // poster) shows while this URL's own image is in flight.
            loaded = nil; loadedURL = nil
            let image = await ImageLoader.shared.image(for: url)
            // SwiftUI cancels this task when the cell scrolls off; don't touch
            // state for a cell that's gone (and the download was cancelled).
            guard !Task.isCancelled else { return }
            if let image { loaded = image; loadedURL = url } else { failed = true }
        }
    }
}

/// Shared image cache + loader. Not an actor: the NSCache is thread-safe and
/// the in-flight bookkeeping is guarded by a lock, so a synchronous
/// memory-cache read is available from a SwiftUI body without an actor hop.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let session: URLSession
    private let memoryCache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    /// One shared download per URL, with a reference count of how many cells
    /// are waiting — so the download is cancelled once the LAST waiter's cell
    /// scrolls away (a fast fling no longer burns bandwidth on posters nobody
    /// will see, starving the visible cells behind them).
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private var waiters: [URL: Int] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "cini-images"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memoryCache.countLimit = 400
        // Cost cap too: 400 DECODED posters can legitimately hold hundreds
        // of MB (NSCache tracks no cost by default) — a jetsam risk for
        // exactly the heavy scrollers.
        memoryCache.totalCostLimit = 96 * 1024 * 1024
    }

    /// Synchronous memory-cache lookup — safe to call from a view body
    /// (NSCache is thread-safe). Nil on a miss.
    func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = memoryCache.object(forKey: url as NSURL) { return cached }

        // Join (or start) the shared download for this URL, +1 waiter.
        let task: Task<UIImage?, Never> = {
            lock.lock(); defer { lock.unlock() }
            if let existing = inFlight[url] {
                waiters[url, default: 0] += 1
                return existing
            }
            let created = Task<UIImage?, Never> { [session] in
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                guard let raw = UIImage(data: data) else { return nil }
                // Decode/decompress OFF the main thread, ONCE, so scrolling
                // never pays JPEG decompression at render-commit time.
                return await raw.byPreparingForDisplay() ?? raw
            }
            inFlight[url] = created
            waiters[url] = 1
            return created
        }()

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // This waiter's cell went away mid-flight.
            self.releaseWaiter(url, cancelled: true)
        }

        // Exactly-once release: onCancel handled the cancelled path (and
        // Task.isCancelled stays true through here), so only a non-cancelled
        // waiter runs the normal completion.
        if !Task.isCancelled {
            releaseWaiter(url, cancelled: false)
            if let result {
                let cost = result.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                memoryCache.setObject(result, forKey: url as NSURL, cost: cost)
            }
        }
        return result
    }

    private func releaseWaiter(_ url: URL, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        let remaining = (waiters[url] ?? 1) - 1
        if remaining <= 0 {
            // Last waiter gone: cancel the download if this was a cancellation
            // (nobody left to want it), and clear the bookkeeping either way.
            if cancelled { inFlight[url]?.cancel() }
            inFlight[url] = nil
            waiters[url] = nil
        } else {
            waiters[url] = remaining
        }
    }
}
