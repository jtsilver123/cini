import SwiftUI
import RankingEngine

/// Everything the user adds while logging, gathered before comparisons
/// and persisted after the rank is committed.
struct EnrichmentDraft {
    var watchedWith: Set<UUID> = []
    var watchDate: Date?
    var notes = ""
    var personalNotes = ""
    var labels: Set<String> = []
    var cast: Set<CastMember> = []
    var stealthMode = false
}

/// The log flow, faithful to Beli's stacked-card overlay and its order:
///
///   1. movie title card (serif, metadata, ×)
///   2. "Add to my list of [Movies ▾]"
///   3. "How was it?" — three colored circles
///   4. details card — who with, labels, notes, date, stealth… then Okay
///   5. "Which do you prefer?"  A —OR— B   (Undo · Too tough · Skip)
///   6. result card — "Ranked #4 · 8.6" → Done
///
/// Presented full-screen over a dimmed scrim so the app shows through.
struct LogFlowView: View {
    let movie: Movie

    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var category: MediaCategory = .movies
    @State private var sentiment: Sentiment?
    @State private var phase: Phase = .sentiment
    @State private var draft = EnrichmentDraft()
    @State private var session: InsertionSession<Int>?
    @State private var scored: ScoredItem<Int>?
    @State private var pairID = 0

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
                    VStack(spacing: 12) {
                        titleCard
                        categoryCard
                        sentimentCard

                        if phase == .enrich || phase == .comparing || phase == .result {
                            EnrichmentCard(
                                movie: movie,
                                draft: $draft,
                                isLocked: phase != .enrich,
                                onOkay: { startComparisons() }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if phase == .comparing, let session, !session.isComplete {
                            comparisonCard(session)
                                .id("compare")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if phase == .result, let scored {
                            resultCard(scored)
                                .id("result")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .onChange(of: phase) { _, newPhase in
                    withAnimation(.snappy) {
                        if newPhase == .comparing { proxy.scrollTo("compare", anchor: .bottom) }
                        if newPhase == .result { proxy.scrollTo("result", anchor: .bottom) }
                    }
                }
            }
        }
        .presentationBackground(.clear)
        .animation(.snappy(duration: 0.25), value: phase)
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
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard()
    }

    // MARK: Card 2 — category

    private var categoryCard: some View {
        HStack(spacing: 10) {
            Text("Add to my list of")
                .font(.body)
            Menu {
                ForEach(MediaCategory.allCases) { option in
                    Button {
                        category = option
                    } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: category.icon)
                    Text(category.title).font(.body.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1.3))
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard()
    }

    // MARK: Card 3 — sentiment circles

    private var sentimentCard: some View {
        VStack(spacing: 18) {
            Text("How was it?")
                .font(.title3.weight(.bold))
            HStack(alignment: .top, spacing: 0) {
                sentimentCircle("I liked it!", color: Theme.sentimentLoved, value: .loved)
                sentimentCircle("It was fine", color: Theme.sentimentFine, value: .fine)
                sentimentCircle("I didn't like it", color: Theme.sentimentDisliked, value: .disliked)
            }
        }
        .padding(.vertical, 22)
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
            VStack(spacing: 12) {
                Circle()
                    .fill(color.opacity(isDimmed ? 0.45 : 1))
                    .frame(width: 68, height: 68)
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
        guard let sentiment else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let newSession = store.beginSession(movie: movie, sentiment: sentiment)
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
                        Circle().fill(Theme.teal).frame(width: 44, height: 44)
                        Text("OR").font(.caption.weight(.heavy)).foregroundStyle(.white)
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
                        .foregroundStyle(current.canUndo ? Theme.teal : Theme.gray.opacity(0.5))
                }
                .disabled(!current.canUndo)

                Spacer()

                Button { choose(.tooToughToCall) } label: {
                    Text("Too tough")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.teal)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .overlay(Capsule().strokeBorder(Theme.teal, lineWidth: 1.4))
                }

                Spacer()

                Button { choose(.skip) } label: {
                    Label("Skip", systemImage: "arrowshape.turn.up.forward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.teal)
                        .labelStyle(TrailingIconLabelStyle())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .padding(20)
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
                    .strokeBorder(Theme.teal.opacity(0.8), lineWidth: 1.4)
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
            await session.loadProfile()    // streak may have just grown
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
        if !draft.notes.isEmpty {
            try? await supabase.upsertNote(movieID: movie.tmdbID, body: draft.notes, isPrivate: false)
        }
        if !draft.personalNotes.isEmpty {
            try? await supabase.upsertNote(movieID: movie.tmdbID, body: draft.personalNotes, isPrivate: true)
        }
        for member in draft.cast {
            try? await supabase.addPerformance(movieID: movie.tmdbID, cast: member)
        }
        if !draft.watchedWith.isEmpty || draft.watchDate != nil {
            try? await supabase.updateRanking(movieID: movie.tmdbID,
                                              watchedWith: Array(draft.watchedWith),
                                              watchDate: draft.watchDate)
        }
        if draft.stealthMode {
            try? await supabase.hideRankEvent(movieID: movie.tmdbID)
        }
    }

    // MARK: Card 6 — result

    private func resultCard(_ scored: ScoredItem<Int>) -> some View {
        VStack(spacing: 14) {
            Text("ADMIT ONE · CINI")
                .font(.system(size: 10, weight: .bold))
                .tracking(3.5)
                .foregroundStyle(Theme.gray)
            if let streak = session.profile?.streakWeeks, streak > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill").font(.caption)
                    Text(streak == 1 ? "Streak started" : "\(streak)-week streak alive")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.gold)
            }
            HStack(spacing: 14) {
                PosterView(url: movie.posterURL, width: 52)
                VStack(alignment: .leading, spacing: 3) {
                    (Text("Ranked ") + Text("#\(scored.rank)").foregroundStyle(Theme.gold))
                        .font(.title3.weight(.bold))
                    Text("on your Watched list").font(.subheadline).foregroundStyle(Theme.gray)
                }
                Spacer()
                ScoreBadge(score: scored.score, size: 56)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            // Ticket perforation
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Theme.hairline)
                .frame(height: 1)
            PillButton(title: "Done") { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .floatingCard()
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
                    .fill(configuration.isPressed ? Theme.tealSoft : .clear)
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
