import SwiftUI

// MARK: - Liquid Glass adoption (iOS 26+/27, mandatory glass era)

extension View {
    /// Capsule Liquid Glass surface where available; hairline fallback on
    /// the iOS 17 floor. Wrap sibling glass shapes in GlassEffectContainer
    /// at the call site so iOS 27 can blend and morph them.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            let glass: Glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: .capsule)
        } else {
            self.background(
                // Solid white here was a latent pre-iOS-26 bug: glaring in
                // the dark room, invisible intent in the light one. The
                // adaptive fill reads as glass in both.
                Capsule().fill(tint ?? Theme.fill)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: tint == nil ? 1 : 0))
            )
        }
    }
}

// MARK: - Keyboard

extension View {
    /// Swiping anywhere puts the keyboard away (complements tap-outside).
    /// Simultaneous + a real drag threshold so taps on buttons — including
    /// UIKit-backed ones like SignInWithAppleButton — are never intercepted.
    func swipeDismissesKeyboard() -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { _ in
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
    }
}

// MARK: - Pill buttons

/// Fully-rounded pill button. Filled velvet = primary, outlined/glass =
/// secondary. Uses the system glass button styles on iOS 26+/27 so it
/// inherits Liquid Glass refinements (and the user's transparency setting).
struct PillButton: View {
    enum Style { case filled, outlined }

    let title: String
    var systemImage: String?
    var style: Style = .filled
    var action: () -> Void = {}

    var body: some View {
        if #available(iOS 26.0, *) {
            if style == .filled {
                Button(action: action) { label(foreground: .white) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.velvet)
            } else {
                Button(action: action) { label(foreground: Theme.marquee) }
                    .buttonStyle(.glass)
            }
        } else {
            Button(action: action) {
                label(foreground: style == .filled ? .white : Theme.marquee)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(style == .filled ? Theme.velvet : .clear))
                    .overlay(Capsule().strokeBorder(style == .filled ? .clear : Theme.marquee, lineWidth: 1.2))
            }
            .buttonStyle(.plain)
        }
    }

    private func label(foreground: Color) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.subheadline.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(foreground)
    }
}

/// Dropdown filter pill: "Genre ∨". Glass surface on iOS 26+/27.
struct FilterPill: View {
    let title: String
    var hasChevron = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline)
                if hasChevron { Image(systemName: "chevron.down").font(.caption2) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
        .glassCapsule()
    }
}

// MARK: - Score badge

/// Circular score badge with thin ring, one-decimal score, and an optional
/// small count chip ("3k") pinned to the lower-right — exactly Beli's.
struct ScoreBadge: View {
    let score: Double
    var count: Int?
    var size: CGFloat = 52

    private var countLabel: String? {
        guard let count else { return nil }
        if count >= 1000 { return "\(count / 1000)k" }
        return "\(count)"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .strokeBorder(Theme.scoreColor(score).opacity(0.45), lineWidth: 1.8)
                .background(Circle().fill(Theme.surface))
                .frame(width: size, height: size)
                .overlay(
                    Text(score.formatted(.number.precision(.fractionLength(1))))
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(Theme.scoreColor(score))
                )
                .shadow(color: Theme.cardShadow, radius: 4, y: 2)
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Circle().fill(Theme.marquee))
                    .offset(x: 4, y: 4)
            }
        }
    }
}

/// Small filled rounded-rect score chip used on the detail hero ("8.4").
struct ScoreChip: View {
    let score: Double

    var body: some View {
        Text(score.formatted(.number.precision(.fractionLength(1))))
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.scoreColor(score)))
    }
}

// MARK: - Segmented pill control

/// Segmented control with active thumb (Leaderboard metrics, Search tabs).
/// The thumb is a Liquid Glass lens on iOS 26+/27.
struct SegmentedPillControl: View {
    let segments: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { i in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = i }
                } label: {
                    Text(segments[i])
                        .font(.subheadline.weight(selection == i ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background { if selection == i { thumb } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.fill))
    }

    @ViewBuilder
    private var thumb: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
        } else {
            Capsule().fill(Theme.surface)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        }
    }
}

/// ShareLink dressed exactly like PillButton's outlined style so share
/// actions sit flush next to regular pills.
struct PillShareLink: View {
    let title: String
    let item: String

    var body: some View {
        if #available(iOS 26.0, *) {
            ShareLink(item: item) {
                label
            }
            .buttonStyle(.glass)
        } else {
            ShareLink(item: item) {
                label
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(Capsule().strokeBorder(Theme.marquee, lineWidth: 1.2))
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.marquee)
    }
}

/// The (+) / bookmark pair that rides artwork (movie hero, feed cards):
/// scrimmed circles, gold fill when saved. One component so the
/// placement and look stay identical app-wide.
struct ArtworkQuickActions: View {
    let movie: Movie
    var onLog: (Movie) -> Void

    @Environment(RankingStore.self) private var store
    @State private var showSaveSheet = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                onLog(movie)
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            Button {
                bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
            } label: {
                Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : .white)
                    .padding(8)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
        .sheet(isPresented: $showSaveSheet) {
            SaveToListSheet(movie: movie)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

/// One bookmark rule everywhere: already saved → instant remove; no
/// custom lists → instant save to Want to Watch; otherwise ask where.
@MainActor
func bookmarkTapped(movie: Movie, store: RankingStore, askDestination: () -> Void) {
    if store.isOnWatchlist(movie.tmdbID) || store.customLists.isEmpty {
        Task { await store.toggleWatchlist(movie: movie) }
    } else {
        Haptics.tap()
        askDestination()
    }
}

/// Where should this go? Want to Watch leads; your own lists (or a new
/// one) sit right under it. One tap saves and closes.
struct SaveToListSheet: View {
    let movie: Movie

    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 12) {
                    PosterView(url: movie.posterURL, width: 36)
                    Text(movie.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

                Button {
                    Task { await store.toggleWatchlist(movie: movie) }
                    dismiss()
                } label: {
                    saveRow(icon: "bookmark.fill", tint: Theme.marquee,
                            title: "Want to Watch", subtitle: "Default")
                }
                .listRowBackground(Theme.background)

                ForEach(store.customLists) { list in
                    Button {
                        Haptics.tap()
                        Task {
                            try? await SupabaseService.shared.cacheMovie(movie)
                            do {
                                try await SupabaseService.shared.addToList(list.id, movieID: movie.tmdbID)
                                ToastCenter.shared.show("Saved to \(list.name)")
                            } catch {
                                ToastCenter.shared.saveFailed()
                            }
                        }
                        dismiss()
                    } label: {
                        saveRow(icon: "list.star", tint: Theme.ink,
                                title: list.name,
                                subtitle: "\(list.count) title\(list.count == 1 ? "" : "s")")
                    }
                    .listRowBackground(Theme.background)
                }

                HStack {
                    TextField("New list", text: $newName)
                    Button("Create & save") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        newName = ""
                        guard !name.isEmpty else { return }
                        Task {
                            if let list = try? await SupabaseService.shared.createList(name: name) {
                                try? await SupabaseService.shared.cacheMovie(movie)
                                try? await SupabaseService.shared.addToList(list.id, movieID: movie.tmdbID)
                                await store.refreshCustomLists()
                                ToastCenter.shared.show("Saved to \(list.name)")
                            } else {
                                ToastCenter.shared.saveFailed()
                            }
                        }
                        dismiss()
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Theme.background)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Save to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func saveRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.gray)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Member row

/// The one member row: avatar, name, @username or reason line, optional
/// trailing accessory (Follow button, checkmark, …). Used by search
/// results, suggestions, and follower lists so they can't drift apart.
struct MemberRow<Accessory: View>: View {
    let avatarURL: URL?
    let title: String
    let subtitle: String
    var subtitleColor: Color = Theme.gray
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: avatarURL, size: 46, name: title)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
            }
            Spacer()
            accessory
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Cards

/// Rounded-rect card with hairline border.
struct HairlineCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 1))
            )
    }
}

// MARK: - Avatars

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 44
    /// Display name or username — no photo shows their initials instead
    /// of a generic silhouette.
    var name: String? = nil

    private var initials: String {
        guard let name, !name.isEmpty else { return "" }
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        CachedAsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            if initials.isEmpty {
                Circle().fill(Theme.gray.opacity(0.25))
                    .overlay(Image(systemName: "person.fill").foregroundStyle(Theme.gray))
            } else {
                Circle().fill(Theme.marqueeSoft)
                    .overlay(
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.marquee)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Progress dots (comparison flow)



// MARK: - Movie filters (shared by My Lists and every member list)

/// The five standard filters. One struct + one bar everywhere, so
/// filtering looks and behaves identically on your lists and anyone
/// else's.
struct MovieFilters: Equatable {
    var genre: String?
    var decade: Int?
    var runtime: Int?         // max minutes
    var streaming = false
    var language: String?     // ISO 639-1

    var isActive: Bool {
        genre != nil || decade != nil || runtime != nil || streaming || language != nil
    }

    func passes(_ movie: Movie) -> Bool {
        if let genre, !movie.genres.contains(genre) { return false }
        if let decade, let year = movie.releaseYear,
           !(decade..<decade + 10).contains(year) { return false }
        if let runtime, let minutes = movie.runtimeMinutes, minutes > runtime { return false }
        if streaming && movie.streamingOn.isEmpty { return false }
        // Unknown language passes — member lists aren't TMDB-enriched.
        if let language, let original = movie.originalLanguage,
           original != language { return false }
        return true
    }
}

/// Horizontal pill row driving a MovieFilters value. The ✕ appears only
/// while something is active and clears everything.
struct MovieFilterBar: View {
    @Binding var filters: MovieFilters
    /// The movies being filtered — genre/language menus derive from them.
    var movies: [Movie]

    private var genres: [String] {
        Array(Set(movies.flatMap(\.genres))).sorted()
    }

    private var languages: [(code: String, name: String)] {
        let codes = Set(movies.compactMap(\.originalLanguage))
        return codes.compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { (code, $0) }
        }
        .sorted { $0.1 < $1.1 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filters.isActive {
                    Button {
                        withAnimation(.snappy) { filters = MovieFilters() }
                    } label: {
                        Image(systemName: "xmark")
                            .padding(10)
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule()
                }
                Menu {
                    Button("All Genres") { filters.genre = nil }
                    ForEach(genres, id: \.self) { genre in
                        Button(genre) { filters.genre = genre }
                    }
                } label: {
                    FilterPill(title: filters.genre ?? "Genre")
                }
                Menu {
                    Button("All Decades") { filters.decade = nil }
                    ForEach(Array(stride(from: 2020, through: 1950, by: -10)), id: \.self) { decade in
                        Button("\(String(decade))s") { filters.decade = decade }
                    }
                } label: {
                    FilterPill(title: filters.decade.map { "\(String($0))s" } ?? "Decade")
                }
                Menu {
                    Button("Anywhere") { filters.streaming = false }
                    Button("Streaming now") { filters.streaming = true }
                } label: {
                    FilterPill(title: filters.streaming ? "Streaming now" : "Streaming")
                }
                Menu {
                    Button("Any runtime") { filters.runtime = nil }
                    Button("Under 100 min") { filters.runtime = 100 }
                    Button("Under 2 hours") { filters.runtime = 120 }
                    Button("Under 2½ hours") { filters.runtime = 150 }
                } label: {
                    FilterPill(title: filters.runtime.map { "< \($0) min" } ?? "Runtime")
                }
                Menu {
                    Button("All Languages") { filters.language = nil }
                    ForEach(languages, id: \.code) { language in
                        Button(language.name) { filters.language = language.code }
                    }
                } label: {
                    FilterPill(title: filters.language.flatMap {
                        Locale.current.localizedString(forLanguageCode: $0)
                    } ?? "Language")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }
}
