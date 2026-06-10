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
                    Button { dismiss() } label: { Image(systemName: "chevron.up") }
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
                            RoundedRectangle(cornerRadius: 10).fill(Theme.gray.opacity(0.2))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.providerName).font(.subheadline.weight(.semibold))
                            Text(label).font(.caption).italic().foregroundStyle(Theme.gray)
                        }
                        Spacer()
                        Button {
                            // TMDB terms require linking through their watch page,
                            // which deep-links to the provider.
                            if let link = providers?.link, let url = URL(string: link) {
                                UIApplication.shared.open(url)
                            }
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
