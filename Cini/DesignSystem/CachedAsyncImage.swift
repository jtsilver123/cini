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
    /// The fetch finished with no image (or there's no URL). Lets us show the
    /// app's loading pulse WHILE a poster is in flight, but fall back to the
    /// caller's static placeholder (film icon, etc.) when there's nothing to load.
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                content(Image(uiImage: loaded))
            } else if url != nil && !failed && showsLoadingPulse {
                // Loading: the app-wide skeleton pulse, so a poster mid-fetch
                // reads as "loading" anywhere it appears — never a dead blank box.
                Rectangle().fill(Theme.fill).modifier(SkeletonPulse())
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            // Reset for the new URL so a recycled cell shows the loading state
            // (not the previous poster) until its own image arrives.
            loaded = nil
            failed = false
            guard let url else { return }
            if let image = await ImageLoader.shared.image(for: url) { loaded = image }
            else { failed = true }
        }
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let memoryCache = NSCache<NSURL, UIImage>()

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
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = memoryCache.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memoryCache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
