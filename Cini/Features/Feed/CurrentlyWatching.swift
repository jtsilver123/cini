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

/// "Friends are watching" as Instagram/Snap-style story circles at the top of
/// the feed. A gold ring means mid-binge; a green ring + check means caught up.
struct FriendsWatchingShelf: View {
    let rows: [FriendWatchingRow]
    var onTap: (FriendWatchingRow) -> Void

    var body: some View {
        if !rows.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(rows) { row in
                        Button { onTap(row) } label: { story(row) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 2)
            }
        }
    }

    private func story(_ row: FriendWatchingRow) -> some View {
        VStack(spacing: 6) {
            AvatarView(url: row.avatarUrl.flatMap { URL(string: $0) }, size: 62,
                       name: preferredName(row.displayName, row.username))
                .overlay(
                    Circle()
                        .strokeBorder(row.caughtUp
                                      ? AnyShapeStyle(Theme.scoreGreen)
                                      : AnyShapeStyle(LinearGradient(colors: [Theme.marquee, Theme.velvet],
                                                                     startPoint: .topLeading, endPoint: .bottomTrailing)),
                                      lineWidth: 2.5)
                        .padding(-4)
                )
                // Caught-up check badge.
                .overlay(alignment: .bottomTrailing) {
                    if row.caughtUp {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.scoreGreen)
                            .background(Circle().fill(Theme.background))
                            .offset(x: 2, y: 2)
                    }
                }
            Text(row.title)
                .font(.caption2)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(width: 74)
        }
        .frame(width: 74)
    }
}

/// The "story" that opens when you tap a watching circle — the friend, the
/// show, how far they are, when they started, and what to do next.
struct WatchingStorySheet: View {
    let row: FriendWatchingRow
    var onOpenShow: (Int) -> Void = { _ in }
    var onPlanTogether: (FriendWatchingRow) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(url: posterURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Theme.surface }
                    .frame(height: 260).frame(maxWidth: .infinity).clipped()
                    .overlay(Color.black.opacity(0.35))
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 10) {
                    AvatarView(url: row.avatarUrl.flatMap { URL(string: $0) }, size: 72,
                               name: preferredName(row.displayName, row.username))
                        .overlay(Circle().strokeBorder(ringStyle, lineWidth: 3).padding(-4))
                    Text("@\(row.username) is watching")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                    Text(row.title)
                        .font(Theme.serif(26)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                .padding(.bottom, 18).padding(.horizontal, 24)
            }
            .frame(height: 260)

            VStack(spacing: 14) {
                // Where they are.
                HStack(spacing: 8) {
                    if row.caughtUp {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.scoreGreen)
                        Text("All caught up").font(.headline).foregroundStyle(Theme.ink)
                    } else if let label = episodeLabel(season: row.season, episode: row.episode) {
                        Image(systemName: "play.tv.fill").foregroundStyle(Theme.marquee)
                        Text(label).font(.headline).foregroundStyle(Theme.ink)
                    } else {
                        Image(systemName: "play.tv.fill").foregroundStyle(Theme.marquee)
                        Text("Watching now").font(.headline).foregroundStyle(Theme.ink)
                    }
                }
                if let started = row.startedAt {
                    Label("Started \(started.formatted(.relative(presentation: .named)))",
                          systemImage: "calendar")
                        .font(.subheadline).foregroundStyle(Theme.gray)
                }
                HStack(spacing: 10) {
                    PillButton(title: "View show") { dismiss(); onOpenShow(row.showId) }
                    PillButton(title: "Watch together", style: .outlined) { dismiss(); onPlanTogether(row) }
                }
                .padding(.top, 4)
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var ringStyle: AnyShapeStyle {
        row.caughtUp
            ? AnyShapeStyle(Theme.scoreGreen)
            : AnyShapeStyle(LinearGradient(colors: [Theme.marquee, Theme.velvet],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var posterURL: URL? {
        guard let path = row.posterPath, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
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

    // Until the season structure loads, cap at the current value so the steppers
    // can't run away to a nonsense "S2 · E47" that friends would then see; once
    // `info` arrives the real caps apply.
    private var maxSeason: Int { info?.numberOfSeasons ?? season }
    private func maxEpisode(_ s: Int) -> Int { info?.seasonEpisodeCounts[s] ?? episode }

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
                    Haptics.tap(); season = s; episode = e; save(caughtUp: true)
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
                Task {
                    do {
                        try await SupabaseService.shared.clearShowProgress(showID: movie.tmdbID)
                    } catch {
                        // Don't leave the UI saying "removed" if the server still
                        // has it — put the controls back and say so.
                        withAnimation(.snappy) { watching = true }
                        ToastCenter.shared.saveFailed()
                    }
                }
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

    private func save(caughtUp: Bool = false) {
        let s = season, e = episode
        Task {
            do {
                try await SupabaseService.shared.cacheMovie(movie)   // FK needs the show cached
                try await SupabaseService.shared.setShowProgress(showID: movie.tmdbID, season: s,
                                                                 episode: e, caughtUp: caughtUp)
                // The RPC drops the Want to Watch row — keep the shared cache in
                // step so the bookmark/list don't show it as still saved.
                store.watchlistSuperseded(movieID: movie.tmdbID)
            } catch {
                ToastCenter.shared.saveFailed()
            }
        }
    }
}
