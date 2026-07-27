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

/// Remembers which watching "stories" you've already opened, so seen ones can
/// sink to the back and dim — no manual dismiss. Keyed by member+show+progress,
/// so a friend moving forward re-surfaces as fresh.
enum WatchingStoriesSeen {
    private static let key = "watchingStoriesSeenDays"
    /// Pre-expiry storage: a plain array of viewed story keys.
    private static let legacyKey = "watchingStoriesSeen"
    private static let cap = 300

    /// Story lifetimes follow the user's local day, not UTC's.
    static func today() -> Int { Date.localDayOrdinal }

    /// Story key → the local day it was viewed. Snap-style lifecycle: viewed
    /// today = dimmed at the back of the shelf; viewed before today = gone
    /// entirely (until the friend advances, which mints a new story key).
    static func seenDays() -> [String: Int] {
        migrateLegacyIfNeeded()
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }

    /// Upgrading users had a plain array of viewed story keys under the old
    /// key. Fold it in as "viewed today" (so those stories dim and age out
    /// normally instead of all resurfacing as unseen), then drop it.
    private static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.array(forKey: legacyKey) as? [String] else { return }
        var map = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
        let day = today()
        for id in legacy where map[id] == nil { map[id] = day }
        defaults.set(map, forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }
    static func markSeen(_ id: String) {
        var map = seenDays()   // also runs the one-shot legacy migration
        guard map[id] == nil else { return }
        map[id] = today()
        if map.count > cap {
            // Drop the oldest views first.
            for (k, _) in map.sorted(by: { $0.value < $1.value }).prefix(map.count - cap) {
                map.removeValue(forKey: k)
            }
        }
        UserDefaults.standard.set(map, forKey: key)
    }
}

/// "Friends are watching" as Instagram/Snap-style story circles at the top of
/// the feed. A gold ring means mid-binge; a green ring + check means caught up.
/// Once you open one it dims and moves to the back so unseen ones stay up front.
struct FriendsWatchingShelf: View {
    let rows: [FriendWatchingRow]
    var onTap: (FriendWatchingRow) -> Void

    @State private var seenDays: [String: Int] = WatchingStoriesSeen.seenDays()

    /// Identity that also folds in the friend's progress timestamp, so when they
    /// advance, the story counts as new again.
    private func key(_ r: FriendWatchingRow) -> String {
        "\(r.id)@\(Int(r.updatedAt.timeIntervalSince1970))"
    }

    private func isSeen(_ r: FriendWatchingRow) -> Bool { seenDays[key(r)] != nil }

    /// Snap-style lifecycle: unseen stories lead, stories viewed TODAY sink
    /// to the back dimmed, and stories viewed before today are gone entirely
    /// (the whole shelf disappears once everything has aged out). A friend
    /// advancing their progress mints a new story key, so they reappear.
    private var ordered: [FriendWatchingRow] {
        let today = WatchingStoriesSeen.today()
        let alive = rows.filter { (seenDays[key($0)] ?? today) >= today }
        return alive.filter { !isSeen($0) } + alive.filter { isSeen($0) }
    }

    var body: some View {
        if !ordered.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(ordered) { row in
                        Button {
                            let k = key(row)
                            WatchingStoriesSeen.markSeen(k)
                            seenDays[k] = WatchingStoriesSeen.today()
                            onTap(row)
                        } label: { story(row, isSeen: isSeen(row)) }
                            .buttonStyle(.plain)
                    }
                }
                // Vertical room so the ring (drawn 4pt outside the avatar) and the
                // caught-up badge aren't clipped; 16pt ends so circles sit inset at
                // rest but scroll cleanly to the screen edges.
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .animation(.snappy, value: ordered)
        }
    }

    private func ringStyle(_ row: FriendWatchingRow, isSeen: Bool) -> AnyShapeStyle {
        if isSeen { return AnyShapeStyle(Theme.gray.opacity(0.5)) }
        return row.caughtUp
            ? AnyShapeStyle(Theme.scoreGreen)
            : AnyShapeStyle(LinearGradient(colors: [Theme.marquee, Theme.velvet],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func story(_ row: FriendWatchingRow, isSeen: Bool) -> some View {
        VStack(spacing: 6) {
            AvatarView(url: row.avatarUrl.flatMap { URL(string: $0) }, size: 62,
                       name: preferredName(row.displayName, row.username))
                .overlay(
                    Circle()
                        .strokeBorder(ringStyle(row, isSeen: isSeen), lineWidth: 2.5)
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
                // Seen stories dim so unseen ones read as the fresh ones.
                .opacity(isSeen ? 0.55 : 1)
            Text(row.title)
                .font(.caption2)
                .foregroundStyle(isSeen ? Theme.gray : Theme.ink)
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
    var onOpenProfile: (FriendWatchingRow) -> Void = { _ in }

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
                    Button { dismiss(); onOpenProfile(row) } label: {
                        AvatarView(url: row.avatarUrl.flatMap { URL(string: $0) }, size: 72,
                                   name: preferredName(row.displayName, row.username))
                            .overlay(Circle().strokeBorder(ringStyle, lineWidth: 3).padding(-4))
                    }
                    .buttonStyle(.plain)
                    Button { dismiss(); onOpenProfile(row) } label: {
                        Text("\(firstName(row.displayName, row.username) ?? row.username) is watching")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
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
        // Reuse the standard poster variant (w342) so this hero shares the
        // already-cached poster instead of forcing a fresh w500 download.
        return TMDBService.imageURL(path: path, size: .poster)
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
    // "Previously on…" recap of the episode BEFORE the one you're on, so it
    // refreshes you without spoiling the current episode.
    @State private var epHeader: String?
    @State private var epOverview: String?

    /// The episode before the current position: the prior episode, or the
    /// previous season's finale when you're on episode 1. nil at the very start
    /// (S1·E1) or before the structure loads.
    private var previousEpisode: (season: Int, episode: Int)? {
        if episode > 1 { return (season, episode - 1) }
        if season > 1, let count = info?.seasonEpisodeCounts[season - 1], count > 0 {
            return (season - 1, count)
        }
        return nil
    }

    /// A finished/cancelled show — "caught up" means you've completed it.
    private var isEnded: Bool {
        if let s = info?.status { return s == "Ended" || s == "Canceled" }
        return false
    }

    /// The furthest you can be: for an ongoing show with a scheduled next
    /// episode, that next episode (you're waiting on it — e.g. S4·E1); otherwise
    /// the last episode that has aired (the finale, for an ended show). nil until
    /// the structure loads.
    private var ceiling: (season: Int, episode: Int)? {
        if !isEnded, let s = info?.nextEpisodeSeason, let e = info?.nextEpisodeNumber {
            return (s, e)
        }
        if let s = info?.lastAiredSeason, let e = info?.lastAiredEpisode {
            return (s, e)
        }
        return nil
    }

    // Cap the steppers at the ceiling (you can't watch past what's aired / the
    // next scheduled episode). Until the structure loads, cap at the current
    // value so they can't run away to a nonsense "S2 · E47".
    private var maxSeason: Int { ceiling?.season ?? info?.numberOfSeasons ?? season }
    private func maxEpisode(_ s: Int) -> Int {
        if let c = ceiling, s >= c.season { return c.episode }   // ceiling season → ceiling episode
        return info?.seasonEpisodeCounts[s] ?? episode           // earlier seasons → full
    }

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
                            ToastCenter.shared.show("Moved from Want to Watch to Watching")
                        }
                        watching = true
                        save(starting: true)
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
            // A "previously on" recap of the prior episode — refreshes you
            // without spoiling the episode you're on. Skipped at S1·E1 or when
            // TMDB has no synopsis.
            if let epHeader, let epOverview, !epOverview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(epHeader)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(epOverview)
                        .font(.caption).foregroundStyle(Theme.gray).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            // "All caught up" means different things by show type.
            if let c = ceiling {
                if isEnded {
                    // You finished a show that's over — it leaves Currently Watching.
                    Button {
                        Haptics.success(); finishShow()
                    } label: {
                        Label("I finished it", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Ongoing: mark caught up — and if you're not yet at the latest
                    // episode you're waiting on (the cap), jump there too. Shown
                    // even once you've manually stepped to the cap, so the
                    // "caught up" signal still fires for manual steppers.
                    let atCeiling = (season == c.season && episode == c.episode)
                    let scheduledNext = info?.nextEpisodeNumber != nil
                    Button {
                        Haptics.tap()
                        if !atCeiling { season = c.season; episode = c.episode }
                        save(caughtUp: true)
                    } label: {
                        Label(!atCeiling && scheduledNext
                                ? "I'm caught up — next is S\(c.season) · E\(c.episode)"
                                : "I'm caught up",
                              systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Episode structure hasn't loaded — still offer "all caught up"
                // (flag current at where they are) so it's available regardless.
                Button {
                    Haptics.tap(); save(caughtUp: true)
                } label: {
                    Label("I'm all caught up", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain)
            }
            // A clearly-labeled remove (the old "Stop" was ambiguous). For an
            // ended show, "I finished it" above already removes it — don't show
            // two buttons that do the same thing.
            if !(isEnded && ceiling != nil) {
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
                    Label("Remove from Watching", systemImage: "xmark.circle")
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
        // Refresh the recap whenever the episode you're on changes.
        .task(id: [season, episode]) {
            epHeader = nil; epOverview = nil
            guard movie.mediaKind == "tv", let prev = previousEpisode else { return }
            let s = season, e = episode
            if let ep = try? await TMDBService.shared.episode(showID: movie.tmdbID,
                                                              season: prev.season, episode: prev.episode),
               s == season, e == episode {
                epHeader = ep.name.map { "Previously on · S\(prev.season) · E\(prev.episode) · \($0)" }
                    ?? "Previously on · S\(prev.season) · E\(prev.episode)"
                epOverview = ep.overview
            }
        }
    }

    /// A +/- stepper capped at `cap`; `onSet` receives the requested new value.
    private func stepper(_ label: String, value: Int, cap: Int, onSet: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            Button { if value > 1 { onSet(value - 1) } } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(value > 1 ? Theme.marquee : Theme.gray.opacity(0.4))
                .accessibilityLabel("Decrease \(label)")
            Text("\(value)")
                .font(.subheadline.weight(.bold)).monospacedDigit().frame(minWidth: 28)
            Button { if value < cap { onSet(value + 1) } } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(value < cap ? Theme.marquee : Theme.gray.opacity(0.4))
                .accessibilityLabel("Increase \(label)")
        }
        .font(.title3)
    }

    /// `starting` is true for the first "I'm watching this" tap — if that write
    /// fails we revert the optimistic `watching = true` so the UI doesn't show
    /// the active controls over a server with no progress row.
    private func save(caughtUp: Bool = false, starting: Bool = false) {
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
                if starting { watching = false }
                ToastCenter.shared.saveFailed()
            }
        }
    }

    /// Finished an ended show — it can't be "currently watching" anymore, so
    /// drop the progress (optimistically; revert if the write fails).
    private func finishShow() {
        withAnimation(.snappy) { watching = false }
        Task {
            do {
                try await SupabaseService.shared.clearShowProgress(showID: movie.tmdbID)
                ToastCenter.shared.show("You finished \(movie.title) 🎬")
            } catch {
                withAnimation(.snappy) { watching = true }
                ToastCenter.shared.saveFailed()
            }
        }
    }
}
