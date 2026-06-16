import SwiftUI

/// "S2 · E5" / "Season 2" / "Episode 5" / nil from optional season+episode.
func episodeLabel(season: Int?, episode: Int?) -> String? {
    switch (season, episode) {
    case let (s?, e?): return "S\(s) · E\(e)"
    case let (s?, nil): return "Season \(s)"
    case (nil, let e?): return "Episode \(e)"
    default: return nil
    }
}

// MARK: - "Friends are watching" shelf (the binging signal on the feed)

struct FriendsWatchingShelf: View {
    let rows: [FriendWatchingRow]
    var onOpen: (Int) -> Void          // show_id

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("FRIENDS ARE WATCHING")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(rows) { row in
                            Button { onOpen(row.showId) } label: { item(row) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func item(_ row: FriendWatchingRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                PosterView(url: posterURL(row.posterPath), width: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let label = episodeLabel(season: row.season, episode: row.episode) {
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                AvatarView(url: row.avatarUrl.flatMap { URL(string: $0) }, size: 24,
                           name: preferredName(row.displayName, row.username))
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                    .padding(5)
            }
            Text("@\(row.username)")
                .font(.caption2)
                .foregroundStyle(Theme.gray)
                .lineLimit(1)
        }
        .frame(width: 96)
    }

    private func posterURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
    }
}

// MARK: - Detail-page control: "I'm watching this" + episode tracker (TV only)

struct WatchingControl: View {
    let movie: Movie

    @State private var watching = false
    @State private var season = 1
    @State private var episode = 1
    @State private var loaded = false

    var body: some View {
        if movie.mediaKind == "tv" {
            HairlineCard {
                if watching {
                    activeControls
                } else {
                    Button {
                        Haptics.tap()
                        watching = true
                        save()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.tv.fill").foregroundStyle(Theme.marquee)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("I'm watching this").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text("Let friends see what you're binging")
                                    .font(.caption).foregroundStyle(Theme.gray)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                guard !loaded else { return }
                if let p = await SupabaseService.shared.myShowProgress(showID: movie.tmdbID) {
                    watching = true
                    season = p.season ?? 1
                    episode = p.episode ?? 1
                }
                loaded = true
            }
        }
    }

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.tv.fill").foregroundStyle(Theme.marquee)
                Text("Currently watching").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Stop") {
                    Haptics.tap()
                    watching = false
                    Task { try? await SupabaseService.shared.clearShowProgress(showID: movie.tmdbID) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
            }
            stepper("Season", value: $season)
            stepper("Episode", value: $episode)
            Text("Friends see you're on S\(season) · E\(episode)")
                .font(.caption).foregroundStyle(Theme.gray)
        }
    }

    private func stepper(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            Button {
                if value.wrappedValue > 1 { value.wrappedValue -= 1; save() }
            } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(value.wrappedValue > 1 ? Theme.marquee : Theme.gray.opacity(0.5))
            Text("\(value.wrappedValue)")
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .frame(minWidth: 28)
            Button {
                value.wrappedValue += 1; save()
            } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.marquee)
        }
        .font(.title3)
    }

    private func save() {
        let s = season, e = episode
        Task {
            do {
                try await SupabaseService.shared.cacheMovie(movie)   // FK needs the show cached
                try await SupabaseService.shared.setShowProgress(showID: movie.tmdbID, season: s, episode: e)
            } catch {
                ToastCenter.shared.saveFailed()
            }
        }
    }
}
