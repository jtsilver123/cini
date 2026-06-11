import SwiftUI
import RankingEngine
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Ask Cini" — AI recommendations chat powered by Apple's on-device
/// Foundation Models (iOS 26+, Apple Intelligence devices). Free, private,
/// no API key: prompts and answers never leave the phone.
///
/// The model is grounded in the user's real Cini data (top rankings,
/// watchlist, taste) and can call a live TMDB search tool, so answers are
/// personal and factual rather than from model memory.
struct CiniChatView: View {
    @Environment(RankingStore.self) private var store
    @Environment(AppSession.self) private var session

    var body: some View {
        if #available(iOS 26.0, *) {
            CiniChatAvailableView(store: store, profile: session.profile)
        } else {
            ChatUnavailableView(message: "Ask Cini needs iOS 26 or later.")
        }
    }
}

struct ChatUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Theme.marquee)
            Text("Ask Cini").font(Theme.serif(28))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Text("Your Recs tab still works everywhere — it's powered by your friends' taste, not AI.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, *)
struct CiniChatAvailableView: View {
    let store: RankingStore
    var profile: Profile?

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isThinking = false
    @State private var session: LanguageModelSession?

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    /// Starter chips built from the user's own shelf, not generic prompts.
    private var starters: [String] {
        var chips = ["What should I watch tonight?"]
        if let top = store.watchedItems.first.flatMap({ store.movie($0.id) }) {
            chips.append("Something like \(top.title) but I haven't seen")
        }
        if !store.watchlist.isEmpty {
            chips.append("Pick from my watchlist for tonight")
        }
        chips.append("Surprise me with a hidden gem")
        return chips
    }

    var body: some View {
        switch SystemLanguageModel.default.availability {
        case .available:
            chat
        case .unavailable(let reason):
            ChatUnavailableView(message: unavailableMessage(reason))
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        ForEach(messages) { message in
                            bubble(message)
                        }
                        if isThinking {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text("Thinking…").font(.caption).foregroundStyle(Theme.gray)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if messages.isEmpty {
                starterChips
            }
            inputBar
        }
        .background(Theme.background)
        .navigationTitle("Ask Cini")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configureSession() }
    }

    private var firstName: String? {
        let name = profile?.displayName.split(separator: " ").first.map(String.init)
        if let name, !name.isEmpty { return name }
        if let username = profile?.username, !username.hasPrefix("user_") { return username }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.marquee)
                Text(firstName.map { "Hey \($0) 👋" } ?? "Ask Cini")
                    .font(Theme.serif(26))
            }
            Text(greeting)
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
        .padding(.horizontal, 16)
    }

    /// A line that proves Cini knows them — never the same cold opener.
    private var greeting: String {
        if let top = store.watchedItems.first.flatMap({ store.movie($0.id) }) {
            return "I know \(top.title) tops your list — let's find the next one. Private and on-device, always."
        }
        if !store.watchlist.isEmpty {
            return "You've got \(store.watchlist.count) movies waiting on your watchlist — want help picking? Private and on-device, always."
        }
        return "Your movie-buff friend who actually remembers what you like. Private and on-device, always."
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(message.isUser ? .white : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(message.isUser ? Theme.marquee : Theme.surface)
                        .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                )
            if !message.isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 16)
        .id(message.id)
    }

    private var starterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(starters, id: \.self) { starter in
                    Button {
                        draft = starter
                        Task { await send() }
                    } label: {
                        Text(starter)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Theme.marqueeSoft))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask for a movie…", text: $draft, axis: .vertical)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.fill))
                .onSubmit { Task { await send() } }
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(Theme.marquee)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isThinking)
        }
        .padding(12)
        .background(.thinMaterial)
    }

    // MARK: - Model session

    private func configureSession() {
        guard session == nil else { return }
        let tasteContext = Self.tasteSummary(store: store)
        let name = firstName ?? "the user"
        let streak = profile.map { $0.streakWeeks } ?? 0
        session = LanguageModelSession(tools: [MovieLookupTool()]) {
            """
            You are Cini, \(name)'s movie-buff friend inside the Cini app — \
            warm, playful, and genuinely opinionated, never corporate. Talk \
            like a friend who knows their taste cold: reference their actual \
            rankings and watchlist by name when relevant ("since you loved \
            X…"). Keep answers short (2-4 sentences), concrete, and specific \
            — always name movies with their year. Prefer their watchlist when \
            they ask what to watch tonight. Use the lookup tool to confirm \
            titles or streaming availability rather than guessing. Never \
            invent scores or friends. \(streak > 0 ? "They're on a \(streak)-week ranking streak — cheer it on when it fits naturally." : "")

            \(name)'s taste profile:
            \(tasteContext)
            """
        }
    }

    /// Compact, on-device summary of the user's data for grounding.
    static func tasteSummary(store: RankingStore) -> String {
        let top = store.watchedItems.prefix(8).compactMap { item -> String? in
            guard let movie = store.movie(item.id) else { return nil }
            return "\(movie.title) (\(item.score), \(item.sentiment.rawValue))"
        }
        let queue = store.watchlist.prefix(10).compactMap { store.movie($0.movieID)?.title }
        let genres = Dictionary(grouping: store.watchedItems.prefix(30)
            .flatMap { store.movie($0.id)?.genres ?? [] }, by: { $0 })
            .sorted { $0.value.count > $1.value.count }
            .prefix(3).map(\.key)
        return """
        Top ranked: \(top.isEmpty ? "none yet" : top.joined(separator: "; "))
        Watchlist: \(queue.isEmpty ? "empty" : queue.joined(separator: ", "))
        Favorite genres: \(genres.isEmpty ? "unknown" : genres.joined(separator: ", "))
        """
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let session, !isThinking else { return }
        draft = ""
        messages.append(ChatMessage(isUser: true, text: text))
        isThinking = true
        defer { isThinking = false }
        do {
            let response = try await session.respond(to: text)
            messages.append(ChatMessage(isUser: false, text: response.content))
        } catch {
            messages.append(ChatMessage(
                isUser: false,
                text: "I hit a snag answering that — try rephrasing, or ask something shorter."
            ))
        }
    }

    private func unavailableMessage(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Ask Cini uses Apple Intelligence, which needs an iPhone 15 Pro or newer."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use Ask Cini."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model — try again in a bit."
        @unknown default:
            return "Ask Cini isn't available on this device right now."
        }
    }
}

/// Live TMDB lookup so the model grounds titles, years, and streaming
/// availability in real data instead of guessing.
@available(iOS 26.0, *)
struct MovieLookupTool: Tool {
    let name = "lookupMovie"
    let description = "Look up a movie by title: returns year, genres, runtime, and where it's streaming in the US."

    @Generable
    struct Arguments {
        @Guide(description: "The movie title to look up")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        let results = (try? await TMDBService.shared.search(query: arguments.title)) ?? []
        guard let movie = results.first else {
            return "No movie found called \"\(arguments.title)\"."
        }
        var summary = "\(movie.title) (\(movie.releaseYear.map(String.init) ?? "?")) — \(movie.genres.joined(separator: ", "))"
        if let detail = try? await TMDBService.shared.details(for: movie.tmdbID) {
            if let runtime = detail.runtimeText { summary += ", \(runtime)" }
            if let providers = try? await TMDBService.shared.watchProviders(for: movie.tmdbID),
               !providers.streamingNames.isEmpty {
                summary += ". Streaming on " + providers.streamingNames.prefix(3).joined(separator: ", ")
            }
        }
        return summary
    }
}

#endif
