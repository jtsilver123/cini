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

// MARK: - iPad native width

extension View {
    /// Makes an iPhone-shaped layout feel native on iPad instead of stretched:
    /// caps the content to a comfortable reading width and centres it, so rows,
    /// switchers, headers, and text stop running edge-to-edge on the larger
    /// canvas. A no-op on iPhone — the screen is already narrower than the cap,
    /// so the inner frame just takes the full width and nothing moves.
    ///
    /// Apply this to a screen's content and keep the screen background OUTSIDE
    /// it (i.e. add `.background(Theme.background)` AFTER this modifier) so the
    /// gutters either side of the centred column fill on iPad.
    func nativeContentWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    /// The standard left/right screen margin (`Theme.screenH`). Use this for a
    /// screen's outermost content gutter so every tab lines up — never a bare
    /// `.padding(.horizontal, 16/20)` for the top-level margin.
    func screenHPadding() -> some View {
        padding(.horizontal, Theme.screenH)
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

    // Already ranked? Mirror the movie page: a green check (tap to rank
    // again) replaces the (+), and the bookmark drops away — a rank means
    // watched, so "save to watch later" no longer makes sense.
    private var isRanked: Bool { store.isWatched(movie.tmdbID) }

    var body: some View {
        HStack(spacing: 14) {
            // You can only rank what's out — an unreleased title shows just
            // the bookmark (save it for when it drops).
            if movie.isReleased {
                Button {
                    onLog(movie)
                } label: {
                    Image(systemName: isRanked ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(isRanked ? Theme.scoreGreen : .white)
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRanked ? "Ranked — rank again" : "Rank this")
            }
            if !isRanked {
                Button {
                    bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
                } label: {
                    Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : .white)
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isOnWatchlist(movie.tmdbID) ? "On your Want to Watch" : "Bookmark to Want to Watch")
            }
        }
        .font(.title3)
        .sheet(isPresented: $showSaveSheet) {
            SaveToListSheet(movie: movie)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Loading skeletons (the app-wide "loading" look)

/// Gentle pulse for placeholder shapes. Nothing in the app shows a bare
/// blank or zeroed screen while loading — it shows the shape of what's
/// coming.
struct SkeletonPulse: ViewModifier {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }
}

/// Feed-card-shaped placeholders.
struct FeedSkeleton: View {
    var cards = 3

    var body: some View {
        VStack(spacing: 18) {
            ForEach(0..<cards, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.fill).frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.fill)
                                .frame(width: 180, height: 12)
                            RoundedRectangle(cornerRadius: 4).fill(Theme.fill)
                                .frame(width: 90, height: 9)
                        }
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 12).fill(Theme.fill)
                        .frame(height: 150)
                }
            }
        }
        .modifier(SkeletonPulse())
    }
}

/// A profile page before its data lands: identity, the two stat cards,
/// the list rows.
struct ProfileSkeleton: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Circle().fill(Theme.fill).frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.fill)
                        .frame(width: 140, height: 16)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.fill)
                        .frame(width: 90, height: 11)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 16).fill(Theme.fill).frame(height: 92)
                RoundedRectangle(cornerRadius: 16).fill(Theme.fill).frame(height: 92)
            }
            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12).fill(Theme.fill).frame(height: 44)
                }
            }
        }
        .modifier(SkeletonPulse())
    }
}

/// One member/row placeholder — avatar + two text lines. The building block
/// for any list that loads (followers, leaderboard, friend pickers), so a
/// loading list shows its *shape* instead of a lonely spinner.
struct RowSkeleton: View {
    var showsLeading = true

    var body: some View {
        HStack(spacing: 12) {
            if showsLeading {
                Circle().fill(Theme.fill).frame(width: 46, height: 46)
            }
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.fill).frame(width: 150, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(Theme.fill).frame(width: 90, height: 9)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// A stack of row skeletons for a loading list.
struct ListSkeleton: View {
    var rows = 6
    var showsLeading = true

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { _ in RowSkeleton(showsLeading: showsLeading) }
        }
        .modifier(SkeletonPulse())
    }
}

/// The one empty-state look: a gold glyph, a serif line with personality, a
/// plain-language nudge, and an optional CTA. Wherever a screen has nothing to
/// show, it should still feel like Cini — not a flat gray sentence.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.marquee)
            Text(title)
                .font(Theme.serif(22))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                PillButton(title: actionTitle, action: action)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }
}

// MARK: - Category chips (Movies · TV Shows — the only two)

/// The one category selector: identical capsule chips wherever a
/// category gets picked (save popup, Lists category sheet).
struct CategoryChips: View {
    @Binding var selection: MediaCategory
    var onPick: (MediaCategory) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MediaCategory.allCases) { option in
                Button {
                    selection = option
                    onPick(option)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.icon)
                        Text(option.title)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(selection == option ? Theme.background : Theme.ink)
                    .background(Capsule().fill(selection == option ? Theme.marquee : Theme.fill))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

/// One bookmark rule everywhere: already saved → instant remove;
/// otherwise the save happens IMMEDIATELY (Want to Watch) and the quick
/// refinement popup follows — category (Movie/TV) and lists. Swiping it
/// away keeps the save; left alone, it dismisses itself.
@MainActor
func bookmarkTapped(movie: Movie, store: RankingStore, askDestination: () -> Void) {
    if store.isOnWatchlist(movie.tmdbID) {
        Task { await store.toggleWatchlist(movie: movie) }
    } else {
        Haptics.tap()
        Task { await store.toggleWatchlist(movie: movie) }
        askDestination()
    }
}

/// The post-save refinement popup: the title is already on Want to
/// Watch. Category chips fix a mislabeled kind on the spot (lists file
/// by category); list rows additionally file it into your lists. Any
/// interaction keeps it open; untouched, it slips away on its own.
struct SaveToListSheet: View {
    let movie: Movie

    @Environment(RankingStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var category: MediaCategory
    @State private var interacted = false
    @State private var notifyStreaming = false
    @State private var revertingToggle = false
    @State private var noteText = ""
    @State private var hiddenFromFeed = false
    @State private var showUnlocks = false
    @State private var watchByOn = false
    @State private var watchByDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now

    init(movie: Movie) {
        self.movie = movie
        _category = State(initialValue: movie.mediaKind == "tv" ? .tvShows : .movies)
    }

    /// Already streamable → an availability alert would be noise.
    private var alreadyStreaming: Bool {
        !(store.movie(movie.tmdbID)?.streamingOn ?? movie.streamingOn).isEmpty
    }

    /// Lists hold one media type — offer only the ones this save fits.
    private var applicableLists: [CustomList] {
        store.customLists.filter { $0.kind == category.mediaKind }
    }

    /// The title is already on Want to Watch (the bookmark saved on tap),
    /// so the goal date just updates that row.
    private func persistWatchBy(_ date: Date?) async {
        await store.setWatchBy(movieID: movie.tmdbID, date: date)
    }

    /// Every action carries the chosen category.
    private var effectiveMovie: Movie {
        var adjusted = movie
        adjusted.mediaKind = category.mediaKind
        return adjusted
    }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 12) {
                    PosterView(url: movie.posterURL, width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(movie.title)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Bookmarked to Want to Watch")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.scoreGreen)
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

                // Applied immediately — swiping away must keep
                // whatever the chips say.
                CategoryChips(selection: $category) { _ in
                    interacted = true
                    let adjusted = effectiveMovie
                    store.overrideMediaKind(adjusted.tmdbID, kind: adjusted.mediaKind)
                    Task {
                        // The instant Want-to-Watch save may still be in
                        // flight carrying the original kind; let it
                        // settle so this write wins.
                        try? await Task.sleep(for: .milliseconds(800))
                        try? await SupabaseService.shared.cacheMovie(adjusted)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

                if !alreadyStreaming {
                    Toggle(isOn: $notifyStreaming) {
                        HStack(spacing: 10) {
                            Image(systemName: "bell")
                                .foregroundStyle(Theme.marquee)
                            Text("Tell me when it's streaming")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .tint(Theme.marquee)
                    .onChange(of: notifyStreaming) { _, enabled in
                        if revertingToggle { revertingToggle = false; return }
                        interacted = true
                        let saved = effectiveMovie
                        Task {
                            // streaming_alerts FKs onto movies — cache first.
                            try? await SupabaseService.shared.cacheMovie(saved)
                            let ok = await SupabaseService.shared.setStreamingAlert(
                                movieID: saved.tmdbID, enabled: enabled)
                            if !ok {
                                // Revert — a toggle that LOOKS on but isn't
                                // is worse than no toggle.
                                ToastCenter.shared.saveFailed()
                                revertingToggle = true
                                notifyStreaming = !enabled
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                }

                // Your lists as one compact chip row — Beli-style. Lists
                // are single-media-type, so only the ones matching the
                // category chips above apply.
                if !applicableLists.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(applicableLists) { list in
                                Button {
                                    Haptics.tap()
                                    let saved = effectiveMovie
                                    Task {
                                        try? await SupabaseService.shared.cacheMovie(saved)
                                        do {
                                            try await SupabaseService.shared.addToList(list.id, movieID: saved.tmdbID)
                                            // Keep the shared cache's count in step.
                                            await store.refreshCustomLists()
                                            ToastCenter.shared.show("Added to \(list.name)")
                                        } catch {
                                            ToastCenter.shared.saveFailed()
                                        }
                                    }
                                    dismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "list.star")
                                        Text(list.name)
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Capsule().strokeBorder(Theme.hairline))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                }

                HStack {
                    TextField("New list", text: $newName)
                        .onChange(of: newName) { _, _ in interacted = true }
                    Button("Create & add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        newName = ""
                        guard !name.isEmpty else { return }
                        let saved = effectiveMovie
                        Task {
                            do {
                                let list = try await SupabaseService.shared.createList(
                                    name: name, mediaKind: saved.mediaKind)
                                try? await SupabaseService.shared.cacheMovie(saved)
                                // Surface a real add failure — don't claim success.
                                try await SupabaseService.shared.addToList(list.id, movieID: saved.tmdbID)
                                await store.refreshCustomLists()
                                ToastCenter.shared.show("Added to \(list.name)")
                            } catch {
                                ToastCenter.shared.saveFailed()
                            }
                        }
                        dismiss()
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

                TextField("Add a note — why you saved it", text: $noteText, axis: .vertical)
                    .lineLimit(1...3)
                    .onChange(of: noteText) { _, _ in interacted = true }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)

                // A "watch by" goal — a gentle deadline for the queue.
                // Movies only: shows are open-ended, not a single sitting.
                if category == .movies {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $watchByOn) {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar")
                                    .foregroundStyle(Theme.marquee)
                                Text("Watch by a date")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .tint(Theme.marquee)
                        .onChange(of: watchByOn) { _, on in
                            interacted = true
                            Task { await persistWatchBy(on ? watchByDate : nil) }
                        }
                        if watchByOn {
                            DatePicker("", selection: $watchByDate, in: Date()...,
                                       displayedComponents: .date)
                                .labelsHidden()
                                .onChange(of: watchByDate) { _, newDate in
                                    interacted = true
                                    Task { await persistWatchBy(newDate) }
                                }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                }

                Button {
                    interacted = true
                    // Stealth Mode is a referral-unlock — locked taps go to the
                    // unlock screen instead of hiding.
                    if !session.isUnlocked("stealth_mode") { showUnlocks = true; return }
                    guard !hiddenFromFeed else { return }
                    hiddenFromFeed = true
                    Task { await SupabaseService.shared.hideWatchlistEvent(movieID: movie.tmdbID) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: !session.isUnlocked("stealth_mode") ? "lock.fill"
                              : (hiddenFromFeed ? "eye.slash.fill" : "eye.slash"))
                            .foregroundStyle(hiddenFromFeed ? Theme.gray : Theme.marquee)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(!session.isUnlocked("stealth_mode") ? "Stealth Mode (locked)"
                                 : (hiddenFromFeed ? "Hidden from feed" : "Hide from feed"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(hiddenFromFeed ? Theme.gray : Theme.ink)
                            Text(!session.isUnlocked("stealth_mode") ? "Invite a friend to unlock"
                                 : "Friends won't see this save")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                        Spacer()
                        if !session.isUnlocked("stealth_mode") {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                        } else if hiddenFromFeed {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hiddenFromFeed && session.isUnlocked("stealth_mode"))
                .listRowBackground(Theme.background)
            }
            .onDisappear {
                let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    Task { await store.setWatchlistNote(movieID: movie.tmdbID, note: note) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Browsing the lists counts as interaction too.
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { _ in interacted = true })
            .background(Theme.background)
            .sheet(isPresented: $showUnlocks) { UnlocksView() }
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Quick-glance popup: if they don't touch it, it leaves
                // on its own (the save already happened).
                try? await Task.sleep(for: .seconds(4))
                if !interacted { dismiss() }
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
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
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
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
            )
    }
}

// MARK: - Avatars

/// The name an avatar or row should lead with: the display name when it's
/// actually set, otherwise the username. Display names arrive as EMPTY
/// strings (not nil) for members who never set one — `??` alone misses
/// them and initials come up blank.
func preferredName(_ displayName: String?, _ username: String?) -> String? {
    if let displayName, !displayName.isEmpty { return displayName }
    return username
}

/// The name to LEAD WITH when referencing a user in copy — their FIRST name
/// (first word of the display name), falling back to the username when they
/// never set a display name. Cini uses first names everywhere a person is
/// referenced (feed, recs, lists, profiles…); full names appear only on the
/// outward-facing web invite page. Avatar initials still take the full name via
/// `preferredName`, so two-letter monograms keep working.
func firstName(_ displayName: String?, _ username: String?) -> String? {
    if let displayName, !displayName.isEmpty,
       let first = displayName.split(separator: " ").first {
        return String(first)
    }
    return username
}

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
    var runtime: Int?              // max minutes
    var streamingProvider: String? // provider name, e.g. "Netflix"

    var isActive: Bool {
        genre != nil || decade != nil || runtime != nil || streamingProvider != nil
    }

    func passes(_ movie: Movie) -> Bool {
        if let genre, !movie.genres.contains(genre) { return false }
        if let decade, let year = movie.releaseYear,
           !(decade..<decade + 10).contains(year) { return false }
        if let runtime, let minutes = movie.runtimeMinutes, minutes > runtime { return false }
        if let streamingProvider,
           !movie.streamingOn.contains(where: { Self.canonicalProvider($0) == streamingProvider }) { return false }
        return true
    }

    /// The major streaming services, in a sensible order — keeps the filter
    /// clean instead of listing TMDB's dozens of regional/ad-tier variants.
    static let majorProviders = ["Netflix", "Max", "Hulu", "Disney+",
                                 "Prime Video", "Apple TV+", "Paramount+", "Peacock"]

    /// Fold a raw TMDB provider name into one of the majors (or nil to drop the
    /// long tail of channels and "with Ads" duplicates).
    static func canonicalProvider(_ name: String) -> String? {
        let n = name.lowercased()
        if n.contains("netflix") { return "Netflix" }
        if n.contains("disney") { return "Disney+" }
        if n.contains("hulu") { return "Hulu" }
        if n.contains("paramount") { return "Paramount+" }
        if n.contains("peacock") { return "Peacock" }
        if n.contains("apple") { return "Apple TV+" }
        if n.contains("prime") { return "Prime Video" }
        if n.contains("hbo") || n == "max" { return "Max" }
        return nil
    }

    /// The clean, ordered set of providers present in a list of movies.
    static func presentProviders(in movies: [Movie]) -> [String] {
        let present = Set(movies.flatMap { $0.streamingOn.compactMap(canonicalProvider) })
        return majorProviders.filter(present.contains)
    }
}

/// Horizontal pill row driving a MovieFilters value. The ✕ appears only
/// while something is active and clears everything.
struct MovieFilterBar: View {
    @Binding var filters: MovieFilters
    /// The movies being filtered — the genre and provider menus derive from them.
    var movies: [Movie]
    /// When set, a leading filter icon (inline with the pills) runs this —
    /// used on My Lists / Recs to open the full filter+sort sheet.
    var onFilterTap: (() -> Void)? = nil

    @State private var providerLogos: [String: URL] = [:]
    @State private var showStreamingPicker = false

    private var genres: [String] {
        Array(Set(movies.flatMap(\.genres))).sorted()
    }

    /// Providers that actually appear in this list, for the Streaming filter —
    /// folded into the majors so the list stays clean.
    private var providers: [String] {
        MovieFilters.presentProviders(in: movies)
    }

    var body: some View {
        // Loose glass capsules in a scroll row render with artifacts
        // (worst in light mode) — Liquid Glass wants its elements grouped
        // in one container.
        if #available(iOS 26.0, *) {
            GlassEffectContainer { bar }
        } else {
            bar
        }
    }

    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Optional leading filter icon, inline with the pills — opens
                // the full filter + sort sheet (My Lists / Recs).
                if let onFilterTap {
                    Button {
                        Haptics.tap()
                        onFilterTap()
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(filters.isActive ? Theme.background : Theme.ink)
                            .padding(9)
                            .background(Circle().fill(filters.isActive ? Theme.marquee : Theme.fill))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filters and sort")
                } else if filters.isActive {
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
                // Order: Streaming, Genre, Runtime, Decade.
                FilterPill(title: filters.streamingProvider ?? "Streaming") {
                    showStreamingPicker = true
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
                    Button("Any runtime") { filters.runtime = nil }
                    Button("Under 100 min") { filters.runtime = 100 }
                    Button("Under 2 hours") { filters.runtime = 120 }
                    Button("Under 2½ hours") { filters.runtime = 150 }
                } label: {
                    FilterPill(title: filters.runtime.map { "< \($0) min" } ?? "Runtime")
                }
                Menu {
                    Button("All Decades") { filters.decade = nil }
                    ForEach(Array(stride(from: 2020, through: 1950, by: -10)), id: \.self) { decade in
                        Button("\(String(decade))s") { filters.decade = decade }
                    }
                } label: {
                    FilterPill(title: filters.decade.map { "\(String($0))s" } ?? "Decade")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        // The Streaming filter is a provider list (with logos), not a menu.
        .sheet(isPresented: $showStreamingPicker) {
            streamingPicker
        }
        .task {
            if providerLogos.isEmpty {
                // Fold raw TMDB names ("HBO Max") to canonical ("Max") so the
                // logo lookup matches the canonical provider options.
                let raw = await TMDBService.shared.providerLogos()
                var canonical: [String: URL] = [:]
                for (name, url) in raw {
                    if let key = MovieFilters.canonicalProvider(name), canonical[key] == nil {
                        canonical[key] = url
                    }
                }
                providerLogos = canonical
            }
        }
    }

    private var streamingPicker: some View {
        NavigationStack {
            List {
                Button {
                    filters.streamingProvider = nil
                    showStreamingPicker = false
                } label: {
                    HStack {
                        Text("Any provider").foregroundStyle(Theme.ink)
                        Spacer()
                        if filters.streamingProvider == nil {
                            Image(systemName: "checkmark").foregroundStyle(Theme.marquee)
                        }
                    }
                }
                ForEach(providers, id: \.self) { name in
                    Button {
                        filters.streamingProvider = name
                        showStreamingPicker = false
                    } label: {
                        HStack(spacing: 12) {
                            providerLogo(name)
                            Text(name).foregroundStyle(Theme.ink)
                            Spacer()
                            if filters.streamingProvider == name {
                                Image(systemName: "checkmark").foregroundStyle(Theme.marquee)
                            }
                        }
                    }
                }
                if providers.isEmpty {
                    Text("No streaming info for this list yet.")
                        .font(.subheadline).foregroundStyle(Theme.gray)
                }
            }
            .navigationTitle("Streaming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showStreamingPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func providerLogo(_ name: String) -> some View {
        if let url = providerLogos[name] {
            CachedAsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(Theme.fill)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(Theme.fill).frame(width: 32, height: 32)
        }
    }
}

// MARK: - Beli-style filter sheet

extension MovieFilters {
    /// How many filters are set — drives the "Apply (N)" button and the badge.
    var activeCount: Int {
        [genre != nil, decade != nil, runtime != nil, streamingProvider != nil].filter { $0 }.count
    }
}

/// A Beli-style filter sheet: a Sort segment up top, then expandable sections
/// (Genre, Decade, Runtime, Streaming) with the current pick shown inline, and
/// a Clear all / Apply (N) footer. Edits a local draft and only commits on
/// Apply, so backing out leaves the list untouched.
struct MovieFilterSheet: View {
    @Binding var filters: MovieFilters
    var movies: [Movie]
    @Binding var sortDescending: Bool
    /// Labels for the two sort directions (contextual: score vs date).
    var sortHighLabel: String
    var sortLowLabel: String
    /// Hidden where order is fixed (e.g. relevance-ranked Recs).
    var showSort: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MovieFilters
    @State private var draftSortDescending: Bool
    /// Provider name → logo URL (TMDB), for the Streaming section.
    @State private var providerLogos: [String: URL] = [:]

    init(filters: Binding<MovieFilters>, movies: [Movie],
         sortDescending: Binding<Bool>, sortHighLabel: String, sortLowLabel: String,
         showSort: Bool = true) {
        _filters = filters
        self.movies = movies
        _sortDescending = sortDescending
        self.sortHighLabel = sortHighLabel
        self.sortLowLabel = sortLowLabel
        self.showSort = showSort
        _draft = State(initialValue: filters.wrappedValue)
        _draftSortDescending = State(initialValue: sortDescending.wrappedValue)
    }

    private var genres: [String] { Array(Set(movies.flatMap(\.genres))).sorted() }
    private var providers: [String] { MovieFilters.presentProviders(in: movies) }
    private let runtimeOptions: [(label: String, value: Int)] =
        [("Under 100 min", 100), ("Under 2 hours", 120), ("Under 2½ hours", 150)]
    private var decades: [Int] { Array(stride(from: 2020, through: 1950, by: -10)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showSort { sortSection }
                    section("Genre", systemImage: "theatermasks", selection: draft.genre,
                            options: genres, label: { $0 }) { draft.genre = $0 }
                    section("Decade", systemImage: "calendar",
                            selection: draft.decade.map { "\(String($0))s" },
                            options: decades.map { "\(String($0))s" }, label: { $0 }) { picked in
                        draft.decade = picked.flatMap { Int($0.dropLast()) }
                    }
                    section("Runtime", systemImage: "clock",
                            selection: draft.runtime.flatMap { v in runtimeOptions.first { $0.value == v }?.label },
                            options: runtimeOptions.map(\.label), label: { $0 }) { picked in
                        draft.runtime = picked.flatMap { l in runtimeOptions.first { $0.label == l }?.value }
                    }
                    if !providers.isEmpty {
                        streamingSection
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            .task {
                if providerLogos.isEmpty {
                    // TMDB keys logos by raw name ("HBO Max"); our options are
                    // canonical ("Max"). Fold so the lookup actually hits.
                    let raw = await TMDBService.shared.providerLogos()
                    var canonical: [String: URL] = [:]
                    for (name, url) in raw {
                        if let key = MovieFilters.canonicalProvider(name), canonical[key] == nil {
                            canonical[key] = url
                        }
                    }
                    providerLogos = canonical
                }
            }
        }
    }

    /// The Streaming section, like `section(...)` but with each provider's logo
    /// shown beside its name (matching the streaming picker elsewhere).
    private var streamingSection: some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(providers, id: \.self) { name in
                    Button {
                        withAnimation(.snappy) {
                            draft.streamingProvider = (draft.streamingProvider == name) ? nil : name
                        }
                    } label: {
                        HStack(spacing: 10) {
                            providerLogo(name)
                            Text(name).foregroundStyle(Theme.ink)
                            Spacer()
                            if draft.streamingProvider == name {
                                Image(systemName: "checkmark").foregroundStyle(Theme.marquee)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tv").foregroundStyle(Theme.marquee).frame(width: 24)
                Text("Streaming").font(.headline).foregroundStyle(Theme.ink)
                if let selection = draft.streamingProvider {
                    Text(selection)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
            }
        }
        .tint(Theme.marquee)
    }

    @ViewBuilder
    private func providerLogo(_ name: String) -> some View {
        if let url = providerLogos[name] {
            CachedAsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Theme.fill)
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.fill).frame(width: 26, height: 26)
        }
    }

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sort by").font(.headline).foregroundStyle(Theme.ink)
            Picker("Sort", selection: $draftSortDescending) {
                Text(sortHighLabel).tag(true)
                Text(sortLowLabel).tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    /// One expandable section. `selection` is the currently-picked option label
    /// (nil = none); picking the same one again clears it.
    @ViewBuilder
    private func section(_ title: String, systemImage: String, selection: String?,
                         options: [String], label: @escaping (String) -> String,
                         set: @escaping (String?) -> Void) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Button {
                        withAnimation(.snappy) { set(selection == option ? nil : option) }
                    } label: {
                        HStack {
                            Text(label(option)).foregroundStyle(Theme.ink)
                            Spacer()
                            if selection == option {
                                Image(systemName: "checkmark").foregroundStyle(Theme.marquee)
                            }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(Theme.marquee).frame(width: 24)
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                if let selection {
                    Text(selection)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
            }
        }
        .tint(Theme.marquee)
    }

    private var footer: some View {
        HStack {
            Button("Clear all") { withAnimation(.snappy) { draft = MovieFilters() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(draft.isActive ? Theme.marquee : Theme.gray)
                .disabled(!draft.isActive)
            Spacer()
            Button {
                filters = draft
                sortDescending = draftSortDescending
                dismiss()
            } label: {
                Text(draft.activeCount > 0 ? "Apply (\(draft.activeCount))" : "Apply")
                    .font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 34).padding(.vertical, 14)
                    .background(Capsule().fill(Theme.velvet))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.thinMaterial)
    }
}
