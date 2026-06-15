import SwiftUI

/// Google-style "Where to watch" panel: provider rows with logo, tier label
/// (Subscription / Rent / Buy), and a Watch deep-link button — grouped
/// Stream → Rent → Buy, powered by TMDB's watch-provider endpoint.
struct WhereToWatchSheet: View {
    let movie: Movie
    let providers: WatchProviders?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let providers {
                    section("Stream", label: "Subscription", providers.flatrate)
                    section("Rent", label: "Rent", providers.rent)
                    section("Buy", label: "Buy", providers.buy)

                    if providers.flatrate == nil && providers.rent == nil && providers.buy == nil {
                        unavailable
                    }
                } else {
                    unavailable
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Where to watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ header: String, label: String, _ list: [WatchProviders.Provider]?) -> some View {
        if let list, !list.isEmpty {
            Section(header) {
                ForEach(list) { provider in
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: provider.logoURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 12).fill(Theme.gray.opacity(0.2))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.providerName).font(.subheadline.weight(.semibold))
                            Text(label).font(.caption).italic().foregroundStyle(Theme.gray)
                        }
                        Spacer()
                        Button {
                            // Best-effort direct link: a universal link into the
                            // provider's app/site search for this title (opens the
                            // native app when installed). Falls back to TMDB's
                            // watch page, which satisfies their attribution terms.
                            let url = Self.deepLink(provider: provider.providerName, title: movie.title)
                                ?? providers?.link.flatMap(URL.init)
                            if let url { UIApplication.shared.open(url) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "play.circle")
                                Text("Watch").font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Universal-link search on the provider for this title. Keyed by
    /// case-insensitive provider-name fragments since TMDB names vary
    /// ("Amazon Video", "Amazon Prime Video", "Max", "HBO Max"…).
    static func deepLink(provider: String, title: String) -> URL? {
        let query = title.urlQueryValueEncoded   // escapes "&" in e.g. "Fast & Furious"
        let name = provider.lowercased()
        let template: String? = switch true {
        case name.contains("netflix"): "https://www.netflix.com/search?q=\(query)"
        case name.contains("max"): "https://play.max.com/search?q=\(query)"
        case name.contains("hulu"): "https://www.hulu.com/search?q=\(query)"
        case name.contains("disney"): "https://www.disneyplus.com/search?q=\(query)"
        case name.contains("amazon") || name.contains("prime"):
            "https://www.amazon.com/s?k=\(query)&i=instant-video"
        case name.contains("apple tv"): "https://tv.apple.com/search?term=\(query)"
        case name.contains("peacock"): "https://www.peacocktv.com/watch/search?q=\(query)"
        case name.contains("paramount"): "https://www.paramountplus.com/search/\(query)/"
        case name.contains("youtube"): "https://www.youtube.com/results?search_query=\(query)%20movie"
        default: nil
        }
        return template.flatMap(URL.init)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv.slash").font(.title).foregroundStyle(Theme.gray)
            Text("No streaming options found")
                .font(.subheadline.weight(.semibold))
            Text("\(movie.title) isn't on any US streaming, rental, or purchase platform right now.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}
