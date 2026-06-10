import SwiftUI
import RankingEngine

/// The log flow, faithful to Beli's stacked-card overlay:
///
///   ┌ movie title card (serif, metadata, ×) ────────────┐
///   ┌ "Add to my list of [🎬 Movies ▾]" ────────────────┐
///   ┌ "How was it?" — three colored circles ────────────┐
///   ┌ "Which do you prefer?" A ─OR─ B                   │
///   │   ↩ Undo      ( Too tough )      Skip ➾           │
///   └ …then morphs into the enrichment card + Okay ─────┘
///
/// Presented full-screen over a dimmed scrim so the app shows through.
struct LogFlowView: View {
    let movie: Movie

    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var category: MediaCategory = .movies
    @State private var sentiment: Sentiment?
    @State private var session: InsertionSession<Int>?
    @State private var scored: ScoredItem<Int>?
    @State private var pairID = 0

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed scrim over whatever screen launched the flow.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { if scored == nil && session == nil { dismiss() } }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    titleCard
                    categoryCard
                    sentimentCard

                    if let session, !session.isComplete {
                        comparisonCard(session)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let scored {
                        EnrichmentCard(movie: movie, scored: scored) {
                            dismiss()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
        }
        .presentationBackground(.clear)
        .animation(.snappy(duration: 0.25), value: sentiment)
        .animation(.snappy(duration: 0.25), value: scored)
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
            Button { dismiss() } label: {
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
    }

    private func pick(_ value: Sentiment) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        sentiment = value
        scored = nil
        let newSession = store.beginSession(movie: movie, sentiment: value)
        if newSession.isComplete {
            session = nil
            commit(newSession)   // first movie ever / first in bucket
        } else {
            withAnimation(.snappy) { session = newSession }
        }
    }

    // MARK: Card 4 — comparison

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
            let result = await store.commit(finished)
            withAnimation(.snappy) {
                session = nil
                scored = result
            }
        }
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
