import SwiftUI
import RankingEngine

/// End-to-end log flow: sentiment → pairwise comparisons → enrichment sheet.
/// Presented as a sheet from anywhere a (+) appears.
struct LogFlowView: View {
    let movie: Movie

    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .sentiment
    @State private var session: InsertionSession<Int>?
    @State private var scored: ScoredItem<Int>?

    enum Step {
        case sentiment
        case comparing
        case enrichment
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .sentiment:
                    SentimentPickerView(movie: movie) { sentiment in
                        startSession(sentiment)
                    }
                case .comparing:
                    if let session {
                        ComparisonView(
                            movie: movie,
                            session: Binding(
                                get: { session },
                                set: { self.session = $0 }
                            ),
                            onComplete: { finishComparisons() }
                        )
                    }
                case .enrichment:
                    if let scored {
                        EnrichmentSheet(movie: movie, scored: scored) { dismiss() }
                    }
                }
            }
            .navigationTitle(movie.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(step == .comparing)
    }

    private func startSession(_ sentiment: Sentiment) {
        let newSession = store.beginSession(movie: movie, sentiment: sentiment)
        session = newSession
        if newSession.isComplete {
            finishComparisons()   // first movie ever / first in bucket
        } else {
            withAnimation(.snappy) { step = .comparing }
        }
    }

    private func finishComparisons() {
        guard let session else { return }
        Task {
            scored = await store.commit(session)
            withAnimation(.snappy) { step = .enrichment }
        }
    }
}

// MARK: - Step 1: sentiment bucket

struct SentimentPickerView: View {
    let movie: Movie
    var onPick: (Sentiment) -> Void

    var body: some View {
        VStack(spacing: 24) {
            PosterView(url: movie.posterURL, width: 140)
                .padding(.top, 24)

            Text("How was it?")
                .font(Theme.serif(28))

            VStack(spacing: 14) {
                sentimentCard("Loved it", emoji: "❤️", sentiment: .loved)
                sentimentCard("It was fine", emoji: "🙂", sentiment: .fine)
                sentimentCard("Didn't like it", emoji: "😕", sentiment: .disliked)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Theme.background)
    }

    private func sentimentCard(_ title: String, emoji: String, sentiment: Sentiment) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onPick(sentiment)
        } label: {
            HStack(spacing: 14) {
                Text(emoji).font(.title)
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 2: head-to-head comparisons

struct ComparisonView: View {
    let movie: Movie
    @Binding var session: InsertionSession<Int>
    var onComplete: () -> Void

    @Environment(RankingStore.self) private var store
    @State private var pairID = 0   // drives the snappy pair transition

    var body: some View {
        VStack(spacing: 28) {
            ProgressDots(total: session.expectedComparisons,
                         completed: session.comparisonsMade)
                .padding(.top, 16)

            Text("Which did you like more?")
                .font(Theme.serif(26))

            if let opponentID = session.currentOpponent,
               let opponent = store.movie(opponentID) {
                HStack(spacing: 16) {
                    comparisonCard(for: movie) { choose(.preferNew) }
                    comparisonCard(for: opponent) { choose(.preferExisting) }
                }
                .padding(.horizontal, 20)
                .id(pairID)
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity),
                                        removal: .opacity))
            }

            Button("Too tough to call") {
                choose(.tooToughToCall)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.gray)

            Spacer()
        }
        .background(Theme.background)
    }

    private func comparisonCard(for movie: Movie, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                PosterView(url: movie.posterURL, width: 150)
                Text(movie.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let year = movie.releaseYear {
                    Text(String(year)).font(.caption).foregroundStyle(Theme.gray)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ComparisonCardStyle())
    }

    private func choose(_ choice: ComparisonChoice) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.18)) {
            session.choose(choice)
            pairID += 1
        }
        if session.isComplete { onComplete() }
    }
}

private struct ComparisonCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
            Rectangle().fill(Theme.gray.opacity(0.2))
                .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(Theme.gray))
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}
