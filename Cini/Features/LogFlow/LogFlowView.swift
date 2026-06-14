import SwiftUI
import RankingEngine

/// Everything the user adds while logging, gathered before comparisons
/// and persisted after the rank is committed.
struct EnrichmentDraft {
    var watchedWith: Set<UUID> = []
    var watchDate: Date?
    /// "home" or "theater" — how they watched it.
    var watchedWhere: String?
    var notes = ""
    var notesContainSpoilers = false
    var cast: Set<CastMember> = []
    var stealthMode = false
}

/// The log flow, faithful to Beli's stacked-card overlay and its order:
///
///   1. movie title card (serif, metadata, ×)
///   2. [Movies ▾] [Want to Watch ▾] — media type + destination chips
///   3. "How was it?" — three colored circles
///   4. details card — who with, labels, notes, date, stealth… then Okay
///   5. "Which do you prefer?"  A —OR— B   (Undo · Too tough · Skip)
///   6. result card — "Ranked #4 · 8.6" → Done
///
/// Presented full-screen over a dimmed scrim so the app shows through.
struct LogFlowView: View {
    let movie: Movie

    init(movie: Movie) {
        self.movie = movie
        // TV shows open as TV — the chip must never claim a show is a movie.
        _category = State(initialValue: movie.mediaKind == "tv" ? .tvShows : .movies)
    }

    @Environment(AppSession.self) private var appSession
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var category: MediaCategory = .movies
    @State private var sentiment: Sentiment?
    @State private var phase: Phase = .sentiment
    @State private var draft = EnrichmentDraft()
    @State private var session: InsertionSession<Int>?
    @State private var scored: ScoredItem<Int>?
    @State private var pairID = 0
    @State private var enrichRow: EnrichmentCard.Row?
    @State private var movieCast: [CastMember] = []
    @State private var shareImage: Image?
    // Two-step reveal: the result lands as a "…" ticket (rating screen),
    // then the score springs in (score screen) — Beli's flow, our brand.
    @State private var scoreRevealed = false
    @State private var didScheduleReveal = false
    // Filing destination next to the media chip: nil = Want to Watch.
    @State private var targetList: CustomList?
    @State private var myLists: [CustomList] = []
    @State private var showNewListAlert = false
    @State private var newListName = ""

    enum Phase {
        case sentiment      // picking a bucket
        case enrich         // details card shown, waiting for Okay
        case comparing      // head-to-head in progress
        case result         // committed; showing rank + score
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { if phase == .sentiment { cancel() } }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        // The result is the whole screen — the earlier cards
                        // fall away so the ticket lands in view, no scrolling.
                        if phase == .result, let scored {
                            resultCard(scored)
                                .id("result")
                                .padding(.top, 40)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            titleCard
                            categoryCard
                            sentimentCard

                            // Beli's order: the details card hands off to the
                            // comparison card — it doesn't stack above it, so
                            // comparing never means scrolling down.
                            if phase == .enrich {
                                EnrichmentCard(
                                    movie: movie,
                                    draft: $draft,
                                    isLocked: false,
                                    onOkay: { startComparisons() },
                                    activeRow: $enrichRow
                                )
                                .id("enrich")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }

                            if phase == .comparing, let session, !session.isComplete {
                                comparisonCard(session)
                                    .id("compare")
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .onChange(of: phase) { _, newPhase in
                    withAnimation(.snappy) {
                        if newPhase == .enrich { proxy.scrollTo("enrich", anchor: .bottom) }
                        if newPhase == .comparing { proxy.scrollTo("compare", anchor: .bottom) }
                        if newPhase == .result { proxy.scrollTo("result", anchor: .bottom) }
                    }
                }
            }
        }
        .presentationBackground(.clear)
        .animation(.snappy(duration: 0.25), value: phase)
        // Editors draw as an overlay INSIDE the flow — sheets presented
        // from a clear-background fullScreenCover silently fail to appear
        // on device, so presentation is avoided entirely.
        .overlay {
            if let row = enrichRow {
                EnrichmentEditorOverlay(row: row, draft: $draft, cast: movieCast) {
                    enrichRow = nil
                }
            }
        }
        .task {
            movieCast = (try? await TMDBService.shared.cast(for: movie.tmdbID)) ?? []
            myLists = (try? await SupabaseService.shared.myLists()) ?? []
        }
    }

    /// Abandoning mid-flow: re-sync from the server in case a re-rank
    /// already removed the local entry.
    private func cancel() {
        if scored == nil && sentiment != nil {
            Task { await store.load() }
        }
        dismiss()
    }

    // MARK: Card 1 — title

    private var titleCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(Theme.serif(24))
                Text([movie.releaseYear.map(String.init),
                      movie.genres.prefix(2).joined(separator: ", ")]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " | "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
            }
            Spacer()
            Button { cancel() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard()
    }

    // MARK: Card 2 — category + list destination

    private var categoryCard: some View {
        // Just the two chips — media type and destination list — so both
        // dropdowns render at full width.
        HStack(spacing: 8) {
            Menu {
                ForEach(MediaCategory.allCases) { option in
                    Button {
                        category = option
                    } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                chipLabel(icon: category.icon, title: category.title)
            }
            // Where it files: Want to Watch by default, or any of your
            // own lists (make one right here).
            Menu {
                Button {
                    targetList = nil
                } label: {
                    Label("Want to Watch", systemImage: "bookmark")
                }
                ForEach(myLists) { list in
                    Button {
                        targetList = list
                    } label: {
                        Label(list.name, systemImage: "list.star")
                    }
                }
                Divider()
                Button {
                    showNewListAlert = true
                } label: {
                    Label("New List…", systemImage: "plus")
                }
            } label: {
                chipLabel(icon: targetList == nil ? "bookmark" : "list.star",
                          title: targetList?.name ?? "Want to Watch")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard()
        .alert("New List", isPresented: $showNewListAlert) {
            TextField("Name (e.g. Best heist movies)", text: $newListName)
            Button("Create") {
                let name = newListName.trimmingCharacters(in: .whitespaces)
                newListName = ""
                guard !name.isEmpty else { return }
                Task {
                    // Through the store so the new list shows everywhere,
                    // not just this filing chip.
                    if let list = await store.createList(name: name, mediaKind: category.mediaKind) {
                        myLists = store.customLists
                        targetList = list
                    }
                }
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
    }

    private func chipLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1.3))
    }

    // MARK: Card 3 — sentiment circles

    private var sentimentCard: some View {
        VStack(spacing: 14) {
            Text("How was it?")
                .font(.title3.weight(.bold))
            HStack(alignment: .top, spacing: 0) {
                sentimentCircle("I liked it!", color: Theme.sentimentLoved, value: .loved)
                sentimentCircle("It was fine", color: Theme.sentimentFine, value: .fine)
                sentimentCircle("I didn't like it", color: Theme.sentimentDisliked, value: .disliked)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .floatingCard()
    }

    private func sentimentCircle(_ label: String, color: Color, value: Sentiment) -> some View {
        let isSelected = sentiment == value
        let isDimmed = sentiment != nil && !isSelected
        return Button {
            pick(value)
        } label: {
            VStack(spacing: 9) {
                Circle()
                    .fill(color.opacity(isDimmed ? 0.45 : 1))
                    .frame(width: 62, height: 62)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .scaleEffect(isSelected ? 1.06 : 1)
                Text(label)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isDimmed ? Theme.gray : Theme.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(phase == .comparing || phase == .result)
    }

    private func pick(_ value: Sentiment) {
        guard phase == .sentiment || phase == .enrich else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        sentiment = value
        withAnimation(.snappy) { phase = .enrich }
    }

    // MARK: Step 4 → 5: Okay starts the comparisons

    private func startComparisons() {
        guard let sentiment, phase == .enrich else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // The category chip is a real override, not decoration — a fixed
        // TMDB mislabel (TV movie, miniseries) files where the user said.
        var effective = movie
        effective.mediaKind = category.mediaKind
        store.overrideMediaKind(effective.tmdbID, kind: effective.mediaKind)
        let newSession = store.beginSession(movie: effective, sentiment: sentiment)
        session = newSession
        if newSession.isComplete {
            commit(newSession)      // first movie ever / first in bucket
        } else {
            withAnimation(.snappy) { phase = .comparing }
        }
    }

    // MARK: Card 5 — comparison

    private func comparisonCard(_ current: InsertionSession<Int>) -> some View {
        VStack(spacing: 18) {
            Text("Which do you prefer?")
                .font(.title3.weight(.bold))

            if let opponentID = current.currentOpponent {
                HStack(spacing: 0) {
                    comparisonOption(
                        title: movie.title,
                        subtitle: movie.releaseYear.map(String.init) ?? "",
                        score: nil
                    ) { choose(.preferNew) }

                    ZStack {
                        Circle().fill(Theme.marquee).frame(width: 44, height: 44)
                        Text("OR").font(.caption.weight(.heavy)).foregroundStyle(Theme.background)
                    }
                    .zIndex(1)
                    .padding(.horizontal, -16)

                    comparisonOption(
                        title: store.movie(opponentID)?.title ?? "—",
                        subtitle: store.movie(opponentID)?.releaseYear.map(String.init) ?? "",
                        score: store.scoredItem(for: opponentID)?.score
                    ) { choose(.preferExisting) }
                }
                .id(pairID)
                .transition(.opacity)
            }

            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        session?.undo()
                        pairID += 1
                    }
                } label: {
                    Label("Undo", systemImage: "arrowshape.turn.up.backward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(current.canUndo ? Theme.marquee : Theme.gray.opacity(0.5))
                }
                .disabled(!current.canUndo)

                Spacer()

                Button { choose(.tooToughToCall) } label: {
                    Text("Too tough")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .overlay(Capsule().strokeBorder(Theme.marquee, lineWidth: 1.4))
                }

                Spacer()

                Button { choose(.skip) } label: {
                    Label("Skip", systemImage: "arrowshape.turn.up.forward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .labelStyle(TrailingIconLabelStyle())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .floatingCard()
    }

    private func comparisonOption(title: String, subtitle: String, score: Double?,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.serif(19))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                    if let score {
                        Text("·").foregroundStyle(Theme.gray)
                        Text(score.formatted(.number.precision(.fractionLength(1))))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.scoreColor(score))
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 170)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.marquee.opacity(0.8), lineWidth: 1.4)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ComparisonCardStyle())
    }

    private func choose(_ choice: ComparisonChoice) {
        guard var current = session else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.18)) {
            current.choose(choice)
            session = current
            pairID += 1
        }
        if current.isComplete {
            commit(current)
        }
    }

    private func commit(_ finished: InsertionSession<Int>) {
        Task {
            let result = await store.commit(finished, watchDate: draft.watchDate)
            await persistDraft()
            await appSession.loadProfile()    // streak may have just grown
            withAnimation(.snappy) {
                session = nil
                scored = result
                phase = .result
            }
        }
    }

    /// Save everything from the details card now that the rank exists.
    private func persistDraft() async {
        let supabase = SupabaseService.shared
        var anySaveFailed = false
        if !draft.notes.isEmpty {
            do {
                try await supabase.upsertNote(movieID: movie.tmdbID, body: draft.notes,
                                              isPrivate: false,
                                              containsSpoilers: draft.notesContainSpoilers)
            } catch { anySaveFailed = true }
        }
        // Every rank is a watch — the diary gets a row even without a date.
        do {
            try await supabase.logWatch(movieID: movie.tmdbID,
                                        on: draft.watchDate ?? .now,
                                        where: draft.watchedWhere)
        } catch { anySaveFailed = true }
        // Filing chip: a chosen custom list gets the title too. (The
        // Want to Watch default is a no-op here — a rank means watched.)
        if let list = targetList {
            try? await supabase.cacheMovie(movie)
            do {
                try await supabase.addToList(list.id, movieID: movie.tmdbID)
            } catch { anySaveFailed = true }
        }
        if !draft.cast.isEmpty {
            do {
                try await supabase.addPerformances(movieID: movie.tmdbID,
                                                   cast: Array(draft.cast))
            } catch { anySaveFailed = true }
        }
        if !draft.watchedWith.isEmpty || draft.watchDate != nil || draft.watchedWhere != nil {
            do {
                try await supabase.updateRanking(movieID: movie.tmdbID,
                                                 watchedWith: Array(draft.watchedWith),
                                                 watchDate: draft.watchDate,
                                                 watchedWhere: draft.watchedWhere)
            } catch { anySaveFailed = true }
            // Tag frequencies just changed — keep the chip order current.
            FriendsCache.shared.warm()
        }
        if draft.stealthMode {
            try? await supabase.hideRankEvent(movieID: movie.tmdbID)
        }
        if anySaveFailed {
            // The rank itself landed; only extras missed. Be specific.
            ToastCenter.shared.show("Some details didn't save — add them from the movie page.")
        }
    }

    // MARK: Card 6 — result

    private func resultCard(_ scored: ScoredItem<Int>) -> some View {
        let profile = appSession.profile
        let name = (profile?.displayName.isEmpty == false ? profile!.displayName : (profile?.username ?? ""))
        return VStack(spacing: 16) {
            RankTicket(
                movie: movie,
                rank: scored.rank,
                name: name,
                handle: profile?.username ?? "",
                streakWeeks: profile?.streakWeeks ?? 0,
                poster: { PosterView(url: movie.posterURL, width: 150) },
                avatar: { AvatarView(url: profile?.avatarURL, size: 38, name: name) },
                score: {
                    if scoreRevealed {
                        ScoreBadge(score: scored.score, size: 64)
                            .overlay { ScoreRevealRing(size: 64) }
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        // Calculates on its own, then springs in — no tap.
                        ScoreRevealPlaceholder(size: 64)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 18, y: 8)

            // Actions arrive with the score, not before — the reveal is the
            // moment; sharing is the reward.
            if scoreRevealed {
                HStack(spacing: 10) {
                    if let shareImage {
                        if #available(iOS 26.0, *) {
                            ShareLink(
                                item: shareImage,
                                preview: SharePreview("\(movie.title) — ranked #\(scored.rank) on Cini",
                                                      image: shareImage)
                            ) {
                                shareLabel
                            }
                            .buttonStyle(.glass)
                        } else {
                            ShareLink(
                                item: shareImage,
                                preview: SharePreview("\(movie.title) — ranked #\(scored.rank) on Cini",
                                                      image: shareImage)
                            ) {
                                shareLabel
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .overlay(Capsule().strokeBorder(Theme.marquee, lineWidth: 1.2))
                            }
                        }
                    }
                    PillButton(title: "Done") { dismiss() }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .onAppear { scheduleReveal() }
        .task { await prepareShareCard(scored) }
    }

    private var shareLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
            Text("Share").font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Theme.marquee)
    }

    /// Auto-reveal a beat after the ticket lands, so the calculating
    /// animation registers before the score springs in.
    private func scheduleReveal() {
        guard !didScheduleReveal else { return }
        didScheduleReveal = true
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            revealScore()
        }
    }

    private func revealScore() {
        guard !scoreRevealed else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) {
            scoreRevealed = true
        }
    }

    /// Render the share ticket once the result shows — poster fetched
    /// up front because ImageRenderer won't wait for async images.
    @MainActor
    private func prepareShareCard(_ scored: ScoredItem<Int>) async {
        guard shareImage == nil else { return }
        var poster: UIImage?
        if let url = movie.posterURL,
           let (data, _) = try? await URLSession.shared.data(from: url) {
            poster = UIImage(data: data)
        }
        let profile = appSession.profile
        var avatar: UIImage?
        if let url = profile?.avatarURL,
           let (data, _) = try? await URLSession.shared.data(from: url) {
            avatar = UIImage(data: data)
        }
        let name = (profile?.displayName.isEmpty == false ? profile!.displayName : (profile?.username ?? ""))
        let card = RankShareCard(movie: movie, scored: scored, poster: poster,
                                 name: name, handle: profile?.username ?? "",
                                 avatar: avatar, streakWeeks: profile?.streakWeeks ?? 0)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let rendered = renderer.uiImage {
            shareImage = Image(uiImage: rendered)
        }
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

struct ComparisonCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isPressed ? Theme.marqueeSoft : .clear)
            )
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Shared poster

struct PosterView: View {
    let url: URL?
    var width: CGFloat

    var body: some View {
        CachedAsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(Theme.gray.opacity(0.18))
                .overlay(Image(systemName: "film").font(.title2).foregroundStyle(Theme.gray))
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }
}
