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
    /// The show's season structure (loads async on the detail page) — used to
    /// cap the steppers and power "I'm caught up".
    var info: TMDBService.ExtendedDetails?

    @Environment(RankingStore.self) private var store
    @State private var watching = false
    @State private var season = 1
    @State private var episode = 1

    private var maxSeason: Int { info?.numberOfSeasons ?? 99 }
    private func maxEpisode(_ s: Int) -> Int { info?.seasonEpisodeCounts[s] ?? 99 }

    var body: some View {
        if movie.mediaKind == "tv" {
            HairlineCard {
                if watching {
                    activeControls
                } else {
                    Button {
                        Haptics.tap()
                        // Starting to watch moves it out of Want to Watch — say so.
                        if store.isOnWatchlist(movie.tmdbID) {
                            ToastCenter.shared.show("Moved out of Want to Watch")
                        }
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
            // Reload per show (a pushed detail is a fresh view, but key it anyway
            // so progress is never carried over from a previous title).
            .task(id: movie.tmdbID) {
                if let p = await SupabaseService.shared.myShowProgress(showID: movie.tmdbID) {
                    watching = true
                    season = p.season ?? 1
                    episode = p.episode ?? 1
                }
            }
        }
    }

    private var activeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.tv.fill").foregroundStyle(Theme.marquee)
                Text("Currently watching").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Friends can see this")
                    .font(.caption2).foregroundStyle(Theme.gray)
            }
            stepper("Season", value: season, cap: maxSeason) {
                season = min(max(1, $0), maxSeason)
                episode = min(episode, maxEpisode(season))   // clamp to the new season
                save()
            }
            stepper("Episode", value: episode, cap: maxEpisode(season)) {
                episode = min(max(1, $0), maxEpisode(season))
                save()
            }
            // Jump straight to the latest aired episode.
            if let s = info?.lastAiredSeason, let e = info?.lastAiredEpisode,
               !(season == s && episode == e) {
                Button {
                    Haptics.tap(); season = s; episode = e; save()
                } label: {
                    Label("I'm caught up (S\(s) · E\(e))", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain)
            }
            // A clearly-labeled remove (the old "Stop" was ambiguous).
            Button {
                Haptics.tap()
                withAnimation(.snappy) { watching = false }
                Task { try? await SupabaseService.shared.clearShowProgress(showID: movie.tmdbID) }
            } label: {
                Label("Remove from Currently Watching", systemImage: "xmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(Capsule().strokeBorder(Theme.hairline))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    /// A +/- stepper capped at `cap`; `onSet` receives the requested new value.
    private func stepper(_ label: String, value: Int, cap: Int, onSet: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            Button { if value > 1 { onSet(value - 1) } } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(value > 1 ? Theme.marquee : Theme.gray.opacity(0.4))
            Text("\(value)")
                .font(.subheadline.weight(.bold)).monospacedDigit().frame(minWidth: 28)
            Button { if value < cap { onSet(value + 1) } } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(value < cap ? Theme.marquee : Theme.gray.opacity(0.4))
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
