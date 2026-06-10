import SwiftUI

/// Poster/backdrop image view backed by a shared URLCache sized for a
/// poster-forward app. Disk-cached so lists scroll warm offline.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let loaded {
                content(Image(uiImage: loaded))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            loaded = await ImageLoader.shared.image(for: url)
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
