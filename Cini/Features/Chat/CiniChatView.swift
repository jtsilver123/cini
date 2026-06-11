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
    @State private var isRevealing = false
    @State private var session: LanguageModelSession?
    @State private var showReviewPicker = false
    @State private var showAttachPicker = false
    @State private var attachedMovie: Movie?
    @State private var logMovie: Movie?
    @State private var needsContextRefresh = false
    @FocusState private var inputFocused: Bool

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
        /// What the agent actually did this turn — confirmation chips.
        var actions: [AgentAction] = []
    }

    /// Starter chips built from the user's own shelf, not generic prompts.
    private var starters: [String] {
        var chips = ["What should I watch tonight?"]
        if let top = store.watchedItems.first.flatMap({ store.movie($0.id) }) {
            chips.append("Something like \(top.title) but I haven't seen")
        }
        if !store.watchlist.isEmpty {
            chips.append("Pick from my Want to Watch list for tonight")
        }
        chips.append("Surprise me with a hidden gem")
        chips.append("What can you do for me?")
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
            if messages.isEmpty {
                // Breeze-style welcome: huge greeting, the composer right
                // under it, keyboard already up. Scrolls so small phones
                // with the keyboard up never clip the composer.
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(firstName.map { "Hi \($0)," } ?? "Hey you,")
                            Text("what are we watching?")
                                .foregroundStyle(Theme.marquee)
                        }
                        .font(Theme.serif(34))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                        composer
                        starterChips
                            .padding(.top, 10)
                        conciergeBar
                            .padding(.top, 2)
                    }
                    .padding(.top, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                bubble(message)
                            }
                            if isThinking {
                                ThinkingTicker()
                                    .padding(.horizontal, 16)
                                    .id("thinking")
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
                conciergeBar
                composer
            }
        }
        .background(Theme.background)
        .navigationTitle(messages.isEmpty ? "" : "Ask Cini")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // The agent's tools act through this bridge.
            ChatAgentBridge.shared.store = store
            ChatAgentBridge.shared.openLogFlow = { logMovie = $0 }
            configureSession()
            // Open ready to type, like a real concierge desk.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                inputFocused = true
            }
        }
        .sheet(isPresented: $showReviewPicker) {
            ChatReviewPicker(title: "Review a movie") { movie in
                showReviewPicker = false
                logMovie = movie
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAttachPicker) {
            ChatReviewPicker(title: "Talk about a movie") { movie in
                attachedMovie = movie
                showAttachPicker = false
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $logMovie, onDismiss: {
            // They may have just ranked something — the next prompt
            // carries a fresh taste snapshot so advice never goes stale.
            needsContextRefresh = true
        }) { movie in
            LogFlowView(movie: movie)
        }
    }

    /// Big friendly composer: multi-line field, a (+) to pull a specific
    /// movie into the conversation, and send.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let attachedMovie {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                    Text(attachedMovie.title).lineLimit(1)
                    Button {
                        self.attachedMovie = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.marqueeSoft))
            }
            TextField("Ask Cini anything…", text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { Task { await send() } }
            HStack {
                Button {
                    showAttachPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.fill))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.marquee))
                }
                .buttonStyle(.plain)
                .disabled((draft.trimmingCharacters(in: .whitespaces).isEmpty
                           && attachedMovie == nil) || isThinking)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.marquee.opacity(0.45), lineWidth: 1.2))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// The concierge's two jobs, always one tap away: pick tonight's
    /// movie, or review something straight from the chat.
    private var conciergeBar: some View {
        HStack(spacing: 10) {
            Button {
                draft = "What should I watch tonight?"
                Task { await send() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "popcorn")
                    Text("What to watch")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.marquee)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.marqueeSoft))
            }
            .buttonStyle(.plain)
            .disabled(isThinking)
            Button {
                showReviewPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text("Review a movie")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.marquee)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.marqueeSoft))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var firstName: String? {
        let name = profile?.displayName.split(separator: " ").first.map(String.init)
        if let name, !name.isEmpty { return name }
        if let username = profile?.username, !username.hasPrefix("user_") { return username }
        return nil
    }

    /// Model replies arrive as markdown — render it (bold titles, lists)
    /// instead of showing raw asterisks. Falls back to plain text.
    private func styled(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 8) {
                Text(styled(message.text))
                    .font(.subheadline)
                    .foregroundStyle(message.isUser ? Theme.background : Theme.ink)
                // Receipts for what the agent DID, not just said.
                if !message.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.actions) { action in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Image(systemName: action.icon)
                                Text(action.label).lineLimit(1)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.scoreGreen)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().strokeBorder(Theme.scoreGreen.opacity(0.5), lineWidth: 1))
                        }
                    }
                }
            }
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

    // MARK: - Model session

    private func configureSession() {
        guard session == nil else { return }
        let tasteContext = Self.tasteSummary(store: store)
        let name = firstName ?? "the user"
        let streak = profile.map { $0.streakWeeks } ?? 0
        session = LanguageModelSession(tools: [
            MovieLookupTool(),
            SaveToWatchlistTool(), RemoveFromWatchlistTool(),
            CreateListTool(), AddToListTool(), RemoveFromListTool(), DeleteListTool(),
            SearchMembersTool(), FollowMemberTool(), UnfollowMemberTool(),
            SendRecTool(), StartRankingTool(), DeleteRatingTool(), MyListsTool(),
        ]) {
            """
            You are Cini, \(name)'s personal movie concierge inside the Cini \
            app — warm, playful, and genuinely opinionated, never corporate. \
            Your two jobs: (1) get them to ONE confident pick for tonight — \
            don't list five options; recommend one (with year), say why it \
            fits THEIR taste, and offer one backup at most. (2) When they \
            mention having seen something, offer to rank it right here with \
            the startRanking tool. Talk like a friend who knows their taste \
            cold — reference their actual rankings and watchlist by name \
            ("since you loved X…"). Keep answers short (2-4 sentences) and \
            end with a gentle nudge to act. Prefer their watchlist when they \
            ask what to watch tonight. Use the lookup tool to confirm titles \
            or streaming availability rather than guessing. Never invent \
            scores or friends.

            You can ACT, not just talk: your tools do everything they could \
            do by tapping — save or remove Want to Watch titles, create and \
            edit and delete lists, find and follow members, send \
            recommendations, open the ranking flow, delete ratings. When \
            they ask for an action, just do it with the tool and confirm in \
            one short line. For destructive actions (deleting a list or a \
            rating) ask once for confirmation and act on their yes. Never \
            claim an action you didn't perform with a tool — receipts for \
            real actions appear under your reply automatically. \
            \(streak > 0 ? "They're on a \(streak)-week ranking streak — cheer it on when it fits naturally." : "")

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
        guard let session, !isThinking, !isRevealing else { return }
        guard !text.isEmpty || attachedMovie != nil else { return }
        draft = ""

        // An attached movie pins the conversation to that title.
        var visible = text
        var prompt = text
        if let movie = attachedMovie {
            let year = movie.releaseYear.map { " (\($0))" } ?? ""
            visible = "🎬 \(movie.title)\(text.isEmpty ? "" : " — \(text)")"
            prompt = text.isEmpty
                ? "Tell me about \(movie.title)\(year) — would I like it given my taste?"
                : "About the movie \(movie.title)\(year): \(text)"
            attachedMovie = nil
        }

        if needsContextRefresh {
            needsContextRefresh = false
            prompt = """
            (Context update — their taste profile right now:
            \(Self.tasteSummary(store: store)))

            \(prompt)
            """
        }

        messages.append(ChatMessage(isUser: true, text: visible))
        isThinking = true
        do {
            let response = try await session.respond(to: prompt)
            isThinking = false
            await reveal(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                // The on-device model refuses some legit movie topics
                // (mental-health docs, true crime) — say what happened
                // instead of a generic shrug.
                isThinking = false
                await reveal("Apple's on-device safety filter balked at that one — it can be touchy about heavy subject matter. Ask it a different way and I'll take another swing.")
            case .exceededContextWindowSize:
                // The chat outgrew the model's window: fresh session
                // (taste context intact), then retry this prompt once.
                self.session = nil
                configureSession()
                if let fresh = self.session,
                   let retried = try? await fresh.respond(to: prompt) {
                    isThinking = false
                    await reveal(retried.content)
                } else {
                    isThinking = false
                    await reveal("Our chat got too long for the on-device model, so I started fresh — ask me that again.")
                }
            default:
                await retryOnce(session: session, prompt: prompt)
            }
        } catch {
            await retryOnce(session: session, prompt: prompt)
        }
    }

    /// Transient on-device hiccups usually clear on a second attempt —
    /// only give up after one quiet retry.
    private func retryOnce(session: LanguageModelSession, prompt: String) async {
        if let retried = try? await session.respond(to: prompt) {
            isThinking = false
            await reveal(retried.content)
        } else {
            isThinking = false
            await reveal("I hit a snag answering that — try rephrasing, or ask something shorter.")
        }
    }

    /// The reply lands word by word, like someone typing back to you —
    /// then the receipts for any tool actions pop in underneath.
    private func reveal(_ full: String) async {
        isRevealing = true
        defer { isRevealing = false }
        messages.append(ChatMessage(isUser: false, text: ""))
        let index = messages.count - 1
        let words = full.split(separator: " ", omittingEmptySubsequences: false)
        var shown = ""
        for word in words {
            shown += (shown.isEmpty ? "" : " ") + word
            messages[index].text = shown
            try? await Task.sleep(for: .milliseconds(38))
        }
        messages[index].text = full
        withAnimation(.snappy) {
            messages[index].actions = ChatAgentBridge.shared.drain()
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

// MARK: - Shared chat chrome (no FoundationModels dependency)

/// The "thinking" state as a little show: pulsing sparkles + rotating
/// film-buff phrases instead of a plain spinner.
struct ThinkingTicker: View {
    @State private var phraseIndex = 0

    private let phrases = [
        "Rolling the projector…",
        "Digging through your rankings…",
        "Consulting the archives…",
        "Cueing up something good…",
        "Checking what your friends loved…",
    ]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.marquee)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(phrases[phraseIndex])
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .contentTransition(.opacity)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeInOut(duration: 0.3)) {
                    phraseIndex = (phraseIndex + 1) % phrases.count
                }
            }
        }
    }
}

/// "Review a movie" from the chat: quick picker over your Want to Watch
/// plus full TMDB search — picking one opens the standard log flow.
struct ChatReviewPicker: View {
    var title: String = "Review a movie"
    var onPick: (Movie) -> Void

    @Environment(RankingStore.self) private var store

    @State private var query = ""
    @State private var results: [Movie] = []
    @State private var searchTask: Task<Void, Never>?

    private var watchlistMovies: [Movie] {
        store.watchlist.compactMap { store.movie($0.movieID) }
    }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                    TextField("Search movies & TV shows", text: $query)
                        .autocorrectionDisabled()
                        .onChange(of: query) { _, _ in schedule() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !watchlistMovies.isEmpty {
                        Text("FROM YOUR WANT TO WATCH")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.gray)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Theme.background)
                        ForEach(watchlistMovies.prefix(10)) { movie in
                            pickRow(movie)
                        }
                    }
                } else {
                    ForEach(results) { movie in
                        pickRow(movie)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pickRow(_ movie: Movie) -> some View {
        MovieSuggestionRow(
            movie: movie,
            onRank: {
                store.cache(movie)
                onPick(movie)
            },
            onOpen: {
                store.cache(movie)
                onPick(movie)
            }
        )
        .listRowBackground(Theme.background)
    }

    private func schedule() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = (try? await TMDBService.shared.search(query: text)) ?? []
        }
    }
}
