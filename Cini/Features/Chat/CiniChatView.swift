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

/// Whether the on-device model could EVER run on this hardware — drives
/// whether the app advertises Ask Cini at all. Fixable states (Apple
/// Intelligence switched off, model still downloading) keep the entry
/// points visible; a device that can never run it shouldn't see a
/// prominent button that dead-ends in an explainer.
enum ChatEligibility {
    @available(iOS 26.0, *)
    static var canEverBeAvailable: Bool {
        #if canImport(FoundationModels)
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
            return false
        }
        return true
        #else
        return false
        #endif
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

    @Environment(TabRouter.self) private var tabRouter
    /// Drives the live "using tools" indicator.
    @State private var bridge = ChatAgentBridge.shared
    @Environment(\.dismiss) private var dismissChat

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
    @State private var watchSheetMovie: Movie?
    @State private var watchSheetProviders: WatchProviders?
    @FocusState private var inputFocused: Bool

    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
        /// What the agent actually did this turn — confirmation chips.
        var actions: [AgentAction] = []
        /// A title the reply discussed — offered as one-tap Save /
        /// Where-to-watch buttons.
        var offerMovie: Movie?
    }

    /// Starter chips built from the user's own shelf, not generic prompts.
    /// (The concierge bar already offers "What should I watch tonight?", so it's
    /// not repeated here.)
    private var starters: [String] {
        var chips: [String] = []
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
        @unknown default:
            ChatUnavailableView(message: "Ask Cini isn't available on this device right now.")
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
                                ThinkingTicker(steps: bridge.steps)
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
                    // Pin the concierge bar + composer above the keyboard, and
                    // inset the transcript so the last bubble clears them.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            conciergeBar
                            composer
                        }
                        .background(Theme.background)
                    }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(messages.isEmpty ? "" : "Ask Cini")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // The agent's tools act through this bridge.
            ChatAgentBridge.shared.store = store
            ChatAgentBridge.shared.openLogFlow = { logMovie = $0 }
            // Context-aware: opened from a movie page, that title arrives
            // already pinned to the conversation.
            if attachedMovie == nil, messages.isEmpty,
               let visible = tabRouter.visibleMovie {
                attachedMovie = visible
            }
            configureSession()
            // Open ready to type, like a real concierge desk.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                inputFocused = true
            }
        }
        .sheet(isPresented: $showReviewPicker) {
            ChatReviewPicker(title: "Review a movie") { movie in
                // Let the picker finish dismissing before presenting the log
                // cover — two presentations in one runloop can swallow the
                // second on device.
                showReviewPicker = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    logMovie = movie
                }
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
        .sheet(item: $watchSheetMovie) { movie in
            WhereToWatchSheet(movie: movie, providers: watchSheetProviders)
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
                    .accessibilityLabel("Remove attached title")
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
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.fill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach a title")
                Spacer()
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.marquee))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .disabled((draft.trimmingCharacters(in: .whitespaces).isEmpty
                           && attachedMovie == nil) || isThinking || session == nil)
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
                // One-tap follow-through on whatever was just discussed.
                if let offer = message.offerMovie, !message.isUser {
                    offerRow(for: offer)
                }
                // Receipts for what the agent DID, not just said.
                if !message.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.actions) { action in
                            // The receipt is a door: tap it to go to the
                            // list/movie/member the agent just touched.
                            Button {
                                if let destination = action.destination {
                                    open(destination)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                    Image(systemName: action.icon)
                                    Text(action.label).lineLimit(1)
                                    if action.destination != nil {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.bold))
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.scoreGreen)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().strokeBorder(Theme.scoreGreen.opacity(0.5), lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(action.destination == nil)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        // Never construct a session against an unavailable model — the
        // unavailable screen is showing; a session here can only hurt.
        guard case .available = SystemLanguageModel.default.availability else { return }
        let tasteContext = Self.tasteSummary(store: store)
        let name = firstName ?? "the user"
        let streak = profile.map { $0.streakWeeks } ?? 0
        session = LanguageModelSession(tools: [
            MovieLookupTool(),
            SaveToWatchlistTool(), RemoveFromWatchlistTool(),
            CreateListTool(), CurateListTool(), AddToListTool(), RemoveFromListTool(), DeleteListTool(),
            SearchMembersTool(), FollowMemberTool(), UnfollowMemberTool(),
            SendRecTool(), RequestRecsTool(), IncomingRecsTool(),
            StartRankingTool(), DeleteRatingTool(), MyListsTool(), RecommendTool(),
            FriendWatchedTool(), FriendWantToWatchTool(), FriendOverlapTool(),
            StreamingAlertTool(), TasteMatchTool(), MyStatsTool(),
            MarkWatchingTool(),
        ]) {
            // Compressed hard: every fixed token here is one less for the
            // conversation in the on-device model's small window.
            """
            You are Cini, \(name)'s movie concierge in the Cini app. Voice: \
            their movie-buff friend — warm, witty, opinionated, casual, \
            contractions; 2–4 sentences; never corporate or robotic \
            ("done, it's on your list", not "the item has been added").

            Picking: ONE confident pick (with year), one backup max — NEVER a \
            long list. Recommendations must be UNSEEN: never suggest a title \
            from their "Already watched" list — they've seen it. "What should \
            I watch" / "recommend me something" = call getRecommendations \
            (their unseen picks) or use their Want to Watch, then commit to \
            ONE tied to their taste ("since you loved X…"). Picks must be \
            famous, beloved titles — nothing obscure unless they ask for deep \
            cuts. Ground every pick with lookupMovie — that puts an add \
            button under your reply. \
            Watching WITH someone (gf, partner, friend)? Ask who — if \
            they're on Cini (@username), the friend tools find what BOTH \
            like; otherwise just honor the constraint. "Is X good?" = \
            check lookupMovie and friend scores, then commit to a take. \
            Slang: gf=girlfriend, bf=boyfriend, tn=tonight, rn=right now, \
            rec=recommendation — never treat these as titles or names. \
            When they mention having seen something, offer startRanking. \
            Never invent scores or friends.

            You have a tool for everything tapping can do — lean on them; \
            their names say what they do. Routing you'd miss otherwise: \
            "ask @sam for a scary movie" = requestRecsFromFriend; "make \
            me a list of [genre/studio/mood/era/awards]" = curateList \
            with 5-8 famous titles you know; "movies/shows with [person]" \
            = curateList with person set (real filmography fills it). \
            Themed and person list asks are explicit — never refuse them. \
            Act ONLY on explicit asks: when recommending or guessing, \
            never save or add — the add button does that. Deletes confirm \
            first. Real actions show receipts automatically — never claim \
            one without the tool. Overlap is the cheat code when they're \
            picking with a friend.

            Understanding: resolve "it"/"that one" from context into a \
            concrete title yourself. Tools fuzzy-match titles and list \
            names ("my heist list" works); getMyLists has their real list \
            names — check it before denying a list exists. Everyday-word \
            titles (Friends, It, Up, Her) are titles: "how can I watch \
            Friends" = lookupMovie, never sendRecommendation. A failed \
            tool call means rethink or ask one short question — never \
            repeat the same call. TV shows are first-class: rank, bookmark, \
            and list them like movies; mid-season ("I'm on S2 of X") = \
            markCurrentlyWatching, not rank. \
            \(streak > 0 ? "They're on a \(streak)-week ranking streak — cheer it on when natural." : "")

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
        Already watched & loved (DON'T recommend these back): \(top.isEmpty ? "none yet" : top.joined(separator: "; "))
        Want to Watch (unseen — great for tonight): \(queue.isEmpty ? "empty" : queue.joined(separator: ", "))
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
        ChatAgentBridge.shared.lastUserPrompt = prompt
        ChatAgentBridge.shared.startTurn()
        isThinking = true
        do {
            let response = try await session.respond(to: prompt)
            await reveal(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                // The on-device model refuses some legit movie topics
                // (mental-health docs, true crime) — say what happened
                // instead of a generic shrug.
                await reveal("Apple's on-device safety filter balked at that one — it can be touchy about heavy subject matter. Ask it a different way and I'll take another swing.")
            case .exceededContextWindowSize:
                // The chat outgrew the model's window: fresh session
                // (taste context intact), then retry this prompt once.
                self.session = nil
                // The failed attempt may have left a stale movie pinned —
                // the retry will set its own if it discusses one.
                ChatAgentBridge.shared.startTurn()
                configureSession()
                if let fresh = self.session,
                   let retried = try? await fresh.respond(to: prompt) {
                    await reveal(retried.content)
                } else {
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
            await reveal(retried.content)
        } else {
            await reveal("I hit a snag answering that — try rephrasing, or ask something shorter.")
        }
    }

    /// "Want to Watch" + "Where to watch" buttons for the title the reply
    /// discussed — acting on a pick should never require typing.
    private func offerRow(for movie: Movie) -> some View {
        HStack(spacing: 8) {
            if store.isOnWatchlist(movie.tmdbID) {
                offerChip(icon: "checkmark", title: "Bookmarked", disabled: true) {}
            } else if !store.isWatched(movie.tmdbID) {
                offerChip(icon: "bookmark", title: "Want to Watch", disabled: false) {
                    Task { await store.toggleWatchlist(movie: movie) }
                }
            }
            offerChip(icon: "play.rectangle", title: "Where to watch", disabled: false) {
                openWhereToWatch(movie)
            }
        }
    }

    private func offerChip(icon: String, title: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(disabled ? Theme.gray : Theme.marquee)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.marqueeSoft.opacity(disabled ? 0.5 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func openWhereToWatch(_ movie: Movie) {
        Haptics.tap()
        Task {
            watchSheetProviders = try? await TMDBService.shared.watchProviders(for: movie.tmdbID)
            watchSheetMovie = movie
        }
    }

    /// A tapped receipt chip: close the chat and land on what the agent
    /// touched. Movie/member reuse the push deep-link plumbing.
    private func open(_ destination: AgentDestination) {
        Haptics.tap()
        dismissChat()
        switch destination {
        case .wantToWatch:
            tabRouter.pendingListsTab = .watchlist
            tabRouter.selection = .lists
        case .listsHome:
            tabRouter.pendingListsTab = nil
            tabRouter.selection = .lists
        case .customList(let id):
            tabRouter.pendingCustomListID = id
            tabRouter.selection = .lists
        case .movie(let id):
            tabRouter.pendingPushMovieID = id
            tabRouter.selection = .feed
        case .member(let id, let username):
            tabRouter.pendingPushMember = MemberRef(id: id, username: username)
            tabRouter.selection = .feed
        }
    }

    /// The reply lands word by word, like someone typing back to you —
    /// then the receipts for any tool actions pop in underneath.
    private func reveal(_ full: String) async {
        // If tools ran, let their checkmarks all land for a beat before
        // the answer types in — the satisfying "done, here's your answer".
        if !ChatAgentBridge.shared.steps.isEmpty {
            ChatAgentBridge.shared.finishSteps()
            try? await Task.sleep(for: .milliseconds(420))
        }
        isThinking = false
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
        let discussed = ChatAgentBridge.shared.lastDiscussedMovie
        ChatAgentBridge.shared.lastDiscussedMovie = nil
        withAnimation(.snappy) {
            messages[index].actions = ChatAgentBridge.shared.drain()
            if let discussed, !store.isWatched(discussed.tmdbID) {
                messages[index].offerMovie = discussed
            }
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
    let description = "Look up a movie or TV show: year, genres, runtime, US streaming. Use for any where/how-can-I-watch question."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("magnifyingglass", "Looking up \(arguments.title)")
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No movie or show found called \"\(arguments.title)\"."
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
    /// Live tool steps for this turn (empty until a tool runs).
    var steps: [ChatAgentBridge.ToolStep] = []

    @State private var phraseIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let phrases = [
        "Rolling the projector…",
        "Digging through your rankings…",
        "Consulting the archives…",
        "Cueing up something good…",
        "Checking what your friends loved…",
    ]

    var body: some View {
        if steps.isEmpty {
            // No tool yet — the playful "thinking" shimmer.
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.marquee)
                    .symbolEffect(.variableColor.iterative,
                                  options: reduceMotion ? .nonRepeating : .repeating)
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
        } else {
            // Claude-style: a tidy checklist of what the tools are doing,
            // ticking off live as each step completes.
            VStack(alignment: .leading, spacing: 7) {
                ForEach(steps) { step in
                    HStack(spacing: 9) {
                        ZStack {
                            if step.done {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.scoreGreen)
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                Image(systemName: step.icon)
                                    .foregroundStyle(Theme.marquee)
                                    .symbolEffect(.pulse,
                                                  options: reduceMotion ? .nonRepeating : .repeating)
                            }
                        }
                        .font(.caption)
                        .frame(width: 16)
                        Text(step.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(step.done ? Theme.gray : Theme.ink)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface2))
            .animation(.snappy(duration: 0.25), value: steps)
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
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
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
