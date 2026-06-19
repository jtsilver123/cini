import SwiftUI

/// Center tab: Movies · Members search, year/decade filter, quick pills, and
/// recents. "Movies you may have seen" now lives in the Watched area — a button
/// here deep-links into it so Search stays focused on finding a title.
struct SearchView: View {
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter

    @State private var tab = 0   // 0 = Movies, 1 = Members
    @State private var query = ""
    @State private var movieResults: [Movie] = []
    @State private var memberResults: [ProfileRow] = []
    @State private var followedFromSearch: Set<UUID> = []
    @State private var suggested: [SuggestedMember] = []
    @State private var contactMatches: [SuggestedMember] = []
    @State private var contactsChecked = false
    @State private var showInvite = false
    @State private var recents: [Movie] = RecentSearches.load()
    @State private var dismissedMaybeSeen: Set<Int> = []
    // "Movies / TV shows" toggle (CIN-34) — filters the browse results to the
    // chosen kind.
    @State private var suggestTV = false
    // Grid (new default) vs list for the browse results (CIN-33).
    @AppStorage("search.suggestionsGrid") private var maybeSeenGrid = true
    // Watched count captured when a rank starts, so we can confirm "added to
    // Watched" once the rank flow closes.
    @State private var watchedCountAtRank = 0
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    /// The query the last finished search ran with — empty-result messages
    /// only show once a search has actually completed for the current text.
    @State private var completedQuery = ""
    @State private var browse: BrowseKind?
    @State private var browseResults: [Movie] = []
    @State private var browseLoaded = false
    @FocusState private var searchFocused: Bool
    /// Drives the poster→detail zoom push (iOS 18+); a plain push below it.
    @Namespace private var posterZoom

    /// One-tap browsing for people who don't want to type.
    enum BrowseKind: String, CaseIterable {
        case popular = "Popular"
        case trending = "Trending"
        case releases = "Releases"

        var icon: String {
            switch self {
            case .popular: "flame"
            case .trending: "chart.line.uptrend.xyaxis"
            case .releases: "calendar"
            }
        }
    }

    var body: some View {
        NavigationStack {
            // Tabs, the search field, and the pill row stay frozen; only
            // results/recents scroll underneath.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    brandRow
                    tabsRow
                    searchFields
                    if tab == 0 { browseRow }
                }
                .screenHPadding()
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if tab == 0 {
                            // TMDB can be slow — skeleton rows say "working
                            // on it" instead of freezing on stale content.
                            if isSearching, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                                SearchSkeleton(kind: .titles)
                            } else if !movieResults.isEmpty {
                                resultsSection
                            } else if !completedQuery.isEmpty {
                                noResultsMessage(
                                    "No titles match \"\(completedQuery)\" — check the spelling, or try a director or genre.")
                            } else if browse != nil {
                                browseSection
                            } else {
                                recentsSection
                                maybeSeenButton
                            }
                        } else if isSearching, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            SearchSkeleton(kind: .members)
                        } else if memberResults.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty {
                            suggestedSection
                        } else if memberResults.isEmpty && !completedQuery.isEmpty {
                            noResultsMessage(
                                "No members match \"\(completedQuery)\" — usernames are exact, so check the spelling.")
                        } else {
                            membersSection
                        }
                    }
                    .screenHPadding()
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .nativeContentWidth()
            .background(Theme.background)
            .fullScreenCover(item: $logMovie, onDismiss: {
                // Ranked one of the suggestions → it's now in Watched; the card
                // animates out of the grid and we confirm where it went (CIN-33).
                if store.watchedCount > watchedCountAtRank {
                    ToastCenter.shared.show("Added to your Watched list 🎬")
                }
            }) { movie in
                LogFlowView(movie: movie)
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
                    .zoomDestination(id: movie.tmdbID, in: posterZoom)
            }
            // The system search tab keeps this view alive, so onAppear
            // alone can miss router flags set while it exists — watch for
            // changes too.
            .onChange(of: tabRouter.openMembersSearch) { _, wantsMembers in
                if wantsMembers {
                    tabRouter.openMembersSearch = false
                    tab = 1
                }
            }
            .onChange(of: tabRouter.pendingSearchBrowse) { _, pendingBrowse in
                if let pendingBrowse {
                    tabRouter.pendingSearchBrowse = nil
                    tab = 0
                    browse = pendingBrowse
                    Task { await loadBrowse() }
                }
            }
            .onAppear {
                if let pendingBrowse = tabRouter.pendingSearchBrowse {
                    tabRouter.pendingSearchBrowse = nil
                    tab = 0
                    browse = pendingBrowse
                    Task { await loadBrowse() }
                } else if tabRouter.openMembersSearch {
                    tabRouter.openMembersSearch = false
                    tab = 1
                } else if query.isEmpty {
                    // Arriving via the + tab with nothing typed: keyboard
                    // up, ready to log a movie.
                    focusSearchSoon()
                }
            }
            // The Search tab stays alive in the TabView, so onAppear won't
            // fire on re-selection — focus whenever we (re)enter Search.
            .onChange(of: tabRouter.selection) { _, sel in
                if sel == .search { focusSearchSoon() }
            }
            .onChange(of: tabRouter.retap[.search, default: 0]) { _, _ in
                focusSearchSoon()
            }
        }
    }

    /// Land in Search with the keyboard up, ready to type — unless we arrived
    /// to browse or already have a query. The short delay lets the view be in
    /// the window so the focus actually takes (setting it too early no-ops).
    private func focusSearchSoon() {
        guard query.isEmpty, browse == nil,
              tabRouter.pendingSearchBrowse == nil, !tabRouter.openMembersSearch else { return }
        Task { @MainActor in
            // The tab-switch transition has to finish before the field can
            // become first responder, and how long that takes varies by device.
            // Make a few attempts — but crucially toggle OFF→ON each time so
            // every attempt is a real focus *edge*. Re-setting an already-true
            // @FocusState is a no-op, so a keyboard the transition dropped never
            // gets re-raised (that's why switching INTO Search failed while a
            // retap, where the view is already settled, worked).
            for attempt in 0..<4 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 250))
                guard tabRouter.selection == .search, query.isEmpty,
                      browse == nil, !tabRouter.openMembersSearch else { return }
                searchFocused = false
                try? await Task.sleep(for: .milliseconds(20))
                guard tabRouter.selection == .search, query.isEmpty else { return }
                searchFocused = true
                // Let the responder settle; if focus stuck, we're done. If the
                // transition rejected it (binding syncs back to false), loop and
                // drive a fresh edge.
                try? await Task.sleep(for: .milliseconds(140))
                if searchFocused { return }
            }
        }
    }

    // MARK: Brand row — wordmark + X back to the page underneath

    private var brandRow: some View {
        HStack {
            Text("cini")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.marquee)
            Spacer()
            Button {
                // Release search focus FIRST — while the field is focused,
                // the system search tab can swallow a programmatic tab
                // switch and the X appears to do nothing.
                searchFocused = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.snappy) { tabRouter.closeSearch() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
    }

    // MARK: Tabs: Movies · Members

    private var tabsRow: some View {
        HStack(spacing: 0) {
            tabButton("Movies/TV", icon: "film", index: 0)
            tabButton("Members", icon: "person.2", index: 1)
        }
    }

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            let switched = tab != index
            withAnimation(.snappy) { tab = index }
            // A typed query searches the tab it was typed in — switching
            // tabs re-runs it in the new domain instead of going blank.
            if switched { scheduleSearch() }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(title).font(.headline)
                }
                .foregroundStyle(tab == index ? Theme.marquee : Theme.gray)
                Rectangle()
                    .fill(tab == index ? Theme.marquee : .clear)
                    .frame(height: 2.5)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: Fields

    private var searchFields: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                TextField(tab == 0 ? "Search movies & TV shows" : "Search members", text: $query)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .onChange(of: query) { _, _ in scheduleSearch() }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        scheduleSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
    }

    /// Release Date · Popular · Trending — browse without typing.
    private var browseRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BrowseKind.allCases, id: \.self) { kind in
                    PillButton(title: kind.rawValue, systemImage: kind.icon,
                               style: browse == kind ? .filled : .outlined) {
                        withAnimation(.snappy) {
                            browse = browse == kind ? nil : kind
                        }
                        Task { await loadBrowse() }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func noResultsMessage(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(Theme.gray)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var browseSection: some View {
        // The heading (with the Movies/TV toggle) stays even when a filter is
        // active — only the import prompt drops away here (CIN-34).
        VStack(alignment: .leading, spacing: 6) {
            HStack { maybeSeenHeading; Spacer(); suggestionsViewToggle }
            maybeSeenCaption
            let results = browseResults.filter {
                matchesToggle($0) && !store.isWatched($0.tmdbID)
                    && !dismissedMaybeSeen.contains($0.tmdbID)
            }
            if results.isEmpty {
                if browseLoaded {
                    Text("Nothing here right now — try another filter.")
                        .font(.subheadline).foregroundStyle(Theme.gray)
                        .padding(.vertical, 12)
                } else {
                    SearchSkeleton(kind: .titles)
                }
            } else {
                suggestions(results)
            }
        }
        .padding(.top, 8)
    }

    private func loadBrowse() async {
        guard let kind = browse else { return }
        browseResults = []
        browseLoaded = false
        var result: [Movie]
        switch kind {
        case .popular:
            // Classics most people have actually seen.
            result = (try? await TMDBService.shared.mostWatched()) ?? []
        case .trending:
            // What Cini members are rating/bookmarking right now.
            let ids = await SupabaseService.shared.trendingTitles()
            let rows = (try? await SupabaseService.shared.movies(ids: ids)) ?? []
            var byID: [Int: Movie] = [:]
            for row in rows { byID[row.tmdbId] = row.asMovie }
            result = ids.compactMap { byID[$0] }   // preserve activity order
            // Fall back to TMDB buzz if Cini activity is still thin.
            if result.count < 5 { result = (try? await TMDBService.shared.trending()) ?? result }
        case .releases:
            // Only titles that are actually out now, newest first.
            result = (try? await TMDBService.shared.nowOut()) ?? []
        }
        guard browse == kind else { return }   // user switched mid-flight
        browseResults = result
        browseLoaded = true
        for movie in result { store.cache(movie) }
    }

    // MARK: Results

    /// Remember a title you acted on from search (opened or ranked) so it
    /// shows in Recents next time.
    private func recordRecent(_ movie: Movie) {
        recents.removeAll { $0.tmdbID == movie.tmdbID }
        recents.insert(movie, at: 0)
        recents = Array(recents.prefix(10))
        RecentSearches.save(recents)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(movieResults) { movie in
                MovieSuggestionRow(
                    movie: movie,
                    onRank: { recordRecent(movie); logMovie = movie },
                    onOpen: { recordRecent(movie); detailMovie = movie },
                    zoomNamespace: posterZoom
                )
                Divider()
            }
        }
    }

    // MARK: Suggested for you (growth: follow lots of people fast)

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !contactMatches.isEmpty {
                Text("FROM YOUR CONTACTS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .padding(.top, 4)
                ForEach(contactMatches) { member in
                    suggestedRow(member, reason: "In your contacts")
                    Divider()
                }
            } else if !contactsChecked {
                Button {
                    Task { await findContacts() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title3)
                            .foregroundStyle(Theme.marquee)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find friends from contacts")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("See who you know on Cini — contacts never leave this check")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)
                .floatingCard(cornerRadius: 16)
                .padding(.vertical, 6)
            } else {
                // Checked but no matches — say so instead of vanishing.
                Text("None of your contacts are on Cini yet — invite them below.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .padding(.vertical, 6)
            }

            Text("SUGGESTED FOR YOU")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.top, 10)
            if suggested.isEmpty {
                Text("Suggestions appear as more members join — invite your crew to get it going.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .padding(.vertical, 12)
            }
            ForEach(suggested) { member in
                suggestedRow(member, reason: suggestionReason(member))
                Divider()
            }

            Button {
                showInvite = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.marquee)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite friends to Cini")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("They enter your @username when they join — you follow each other automatically")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    Spacer()
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            .floatingCard(cornerRadius: 16)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
                .presentationDetents([.large])
        }
        .task {
            if suggested.isEmpty {
                suggested = (try? await SupabaseService.shared.suggestedMembers()) ?? []
            }
        }
    }

    private func suggestionReason(_ member: SuggestedMember) -> String {
        if let pct = member.matchPct, pct > 0 {
            return "\(Int(pct))% taste match · \(member.watched) films"
        }
        return member.watched > 0 ? "\(member.watched) films ranked" : "New here too"
    }

    private func suggestedRow(_ member: SuggestedMember, reason: String) -> some View {
        NavigationLink {
            MemberProfileView(userID: member.id, username: member.username)
        } label: {
            MemberRow(
                avatarURL: member.avatarUrl.flatMap(URL.init),
                title: firstName(member.displayName, member.username) ?? member.username,
                subtitle: reason,
                subtitleColor: Theme.scoreGreen
            ) {
                PillButton(title: followedFromSearch.contains(member.id) ? "Following" : "Follow",
                           style: followedFromSearch.contains(member.id) ? .outlined : .filled) {
                    Task { await toggleFollow(member.id) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func findContacts() async {
        contactsChecked = true
        let emails = await ContactsEmails.fetch()
        guard !emails.isEmpty else { return }
        contactMatches = (try? await SupabaseService.shared.membersFromEmails(emails)) ?? []
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(memberResults) { member in
                NavigationLink {
                    MemberProfileView(userID: member.id, username: member.username)
                } label: {
                    MemberRow(
                        avatarURL: member.avatarUrl.flatMap(URL.init),
                        title: firstName(member.displayName, member.username) ?? member.username,
                        subtitle: "@\(member.username)"
                    ) {
                        PillButton(title: followedFromSearch.contains(member.id) ? "Following" : "Follow",
                                   style: .outlined) {
                            Task { await toggleFollow(member.id) }
                        }
                    }
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var recentsSection: some View {
        Group {
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recents").font(.headline)
                    ForEach(recents.prefix(5)) { movie in
                        HStack(spacing: 12) {
                            Image(systemName: "clock").foregroundStyle(Theme.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.title).font(.subheadline.weight(.semibold))
                                Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray)
                            }
                            Spacer()
                            Button {
                                recents.removeAll { $0.tmdbID == movie.tmdbID }
                                RecentSearches.save(recents)
                            } label: {
                                Image(systemName: "xmark").foregroundStyle(Theme.gray)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { detailMovie = movie }
                    }
                }
            }
        }
    }

    // MARK: "Movies you may have seen"

    /// Popular-title suggestions for cold start. Imported titles waiting to
    /// be ranked live in Your Lists → Watched → Pending, not here.
    /// Deep-links into the Watched area's "Movies you may have seen" sheet,
    /// keeping Search itself focused on finding a specific title.
    private var maybeSeenButton: some View {
        Button {
            Haptics.tap()
            tabRouter.selection = .swipe
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3).foregroundStyle(Theme.marquee)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Movies you may have seen")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("Swipe titles you've already watched to rank them")
                        .font(.caption).foregroundStyle(Theme.gray)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatingCard(cornerRadius: 16)
        .padding(.top, 4)
    }

    /// Movies vs TV, per the browse heading toggle.
    private func matchesToggle(_ movie: Movie) -> Bool {
        suggestTV ? movie.mediaKind == "tv" : movie.mediaKind != "tv"
    }

    /// Grid (default) or list renderer for a set of suggestions (CIN-33).
    @ViewBuilder
    private func suggestions(_ list: [Movie]) -> some View {
        if maybeSeenGrid {
            SuggestionGrid(
                movies: list,
                onRank: { watchedCountAtRank = store.watchedCount; logMovie = $0 },
                onSave: { movie in
                    guard !store.isOnWatchlist(movie.tmdbID) else { return }
                    Task { await store.toggleWatchlist(movie: movie) }
                    ToastCenter.shared.show("Saved to Want to Watch ✓")
                },
                onDismiss: { movie in
                    withAnimation(.snappy) { _ = dismissedMaybeSeen.insert(movie.tmdbID) }
                }
            )
            .padding(.top, 4)
        } else {
            ForEach(list) { movie in
                MovieSuggestionRow(
                    movie: movie,
                    onRank: { watchedCountAtRank = store.watchedCount; logMovie = movie },
                    onOpen: { detailMovie = movie },
                    onDismiss: { dismissedMaybeSeen.insert(movie.tmdbID) },
                    zoomNamespace: posterZoom
                )
                Divider()
            }
        }
    }

    /// Tells people what this area is for — finding titles they've already
    /// watched so they can rank them now — plus the grid gestures (CIN-33).
    @ViewBuilder
    private var maybeSeenCaption: some View {
        if maybeSeenGrid {
            Label("Rank what you've already watched — tap a poster to rank, hold to save, ✕ to skip.",
                  systemImage: "hand.tap.fill")
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 2)
        } else {
            Text("Rank what you've already watched.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
    }

    /// Grid/List switch for the suggestions area.
    private var suggestionsViewToggle: some View {
        Button {
            withAnimation(.snappy) { maybeSeenGrid.toggle() }
        } label: {
            Image(systemName: maybeSeenGrid ? "list.bullet" : "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(maybeSeenGrid ? "Show as list" : "Show as grid")
    }

    /// "**Movies** you may have seen" — the leading word is a bold toggle that
    /// flips Movies ↔ TV shows and re-filters the suggestions (CIN-34).
    private var maybeSeenHeading: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { suggestTV.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(suggestTV ? "TV shows" : "Movies").fontWeight(.heavy)
                    Image(systemName: "arrow.left.arrow.right").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            Text(" you may have seen").foregroundStyle(Theme.ink)
        }
        .font(.headline)
    }

    // MARK: Data

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        completedQuery = ""
        guard !text.isEmpty else {
            movieResults = []
            memberResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))   // debounce
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            if tab == 0 {
                // Genre and director queries are first-class: "horror"
                // fills with the genre's most popular, "nolan" with his
                // filmography — both lead the title matches.
                async let genreTask: [Movie] = {
                    guard let genreID = TMDBService.genreID(matching: text) else { return [] }
                    return (try? await TMDBService.shared.popular(genreID: genreID)) ?? []
                }()
                async let directorTask: [Movie] = text.count >= 4
                    ? ((try? await TMDBService.shared.directedMovies(matching: text)) ?? [])
                    : []
                var results = (try? await TMDBService.shared.search(query: text, year: nil)) ?? []
                // Subtitle queries ("new hope") match famous films via
                // their alternative titles, but TMDB buries them on page 2.
                // When page 1 has no notable title, pull the next page so
                // the popularity ranking below can rescue them.
                if results.map({ $0.popularity ?? 0 }).max() ?? 0 < 5, results.count >= 15 {
                    let more = (try? await TMDBService.shared.search(query: text, year: nil, page: 2)) ?? []
                    for movie in more where !results.contains(where: { $0.tmdbID == movie.tmdbID }) {
                        results.append(movie)
                    }
                }
                // TMDB goes blank on typos — retry with progressively
                // trimmed input, then the longest word on its own.
                if results.count < 3, text.count > 3 {
                    var attempts: [String] = []
                    var trimmed = text
                    for _ in 0..<2 where trimmed.count > 3 {
                        trimmed = String(trimmed.dropLast())
                        attempts.append(trimmed)
                    }
                    if let longest = text.split(separator: " ").max(by: { $0.count < $1.count }),
                       longest.count > 3, String(longest) != text {
                        attempts.append(String(longest))
                    }
                    for attempt in attempts where results.count < 5 {
                        guard !Task.isCancelled else { return }
                        let more = (try? await TMDBService.shared.search(query: attempt, year: nil)) ?? []
                        for movie in more where !results.contains(where: { $0.tmdbID == movie.tmdbID }) {
                            results.append(movie)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                // Title similarity and popularity in roughly equal measure:
                // big films win loose queries ("new hope" -> Star Wars, pop
                // 27 vs 0.5) while typo-corrected and exact matches still
                // top their own searches. Weights validated against live
                // TMDB data for all three cases.
                if results.count > 1 {
                    let needle = text.lowercased().trimmingCharacters(in: .whitespaces)
                    func rank(_ movie: Movie) -> Double {
                        var similarity = Fuzzy.similarity(query: text, candidate: movie.title)
                        if movie.title.lowercased().contains(needle) {
                            similarity = max(similarity, 0.82)
                        }
                        return 0.5 * similarity + 0.6 * min(movie.popularity ?? 0, 30) / 30
                    }
                    results.sort { rank($0) > rank($1) }
                }
                // Director matches lead, then the genre's most popular,
                // then title matches — deduped.
                let special = (await directorTask) + (await genreTask)
                if !special.isEmpty {
                    var merged: [Movie] = []
                    var seen = Set<Int>()
                    for movie in special + results where seen.insert(movie.tmdbID).inserted {
                        merged.append(movie)
                    }
                    results = merged
                }
                guard !Task.isCancelled else { return }
                movieResults = results
                completedQuery = text
                for movie in movieResults { store.cache(movie) }
            } else {
                let found = (try? await SupabaseService.shared.searchMembers(query: text)) ?? []
                guard !Task.isCancelled else { return }
                memberResults = found
                completedQuery = text
            }
        }
    }

    /// Optimistic follow toggle that REVERTS on failure — a swallowed
    /// error used to leave the button stuck on "Following".
    private func toggleFollow(_ memberID: UUID) async {
        let wasFollowing = followedFromSearch.contains(memberID)
        if wasFollowing { followedFromSearch.remove(memberID) }
        else { followedFromSearch.insert(memberID) }
        do {
            if wasFollowing { try await SupabaseService.shared.unfollow(memberID) }
            else { try await SupabaseService.shared.requestFollow(memberID) }
        } catch {
            if wasFollowing { followedFromSearch.insert(memberID) }
            else { followedFromSearch.remove(memberID) }
            ToastCenter.shared.saveFailed()
        }
    }
}

/// Suggestion row: title, year + director, quick (+) rank, bookmark, dismiss.
struct MovieSuggestionRow: View {
    let movie: Movie
    var onRank: () -> Void = {}
    var onOpen: () -> Void = {}
    var onDismiss: (() -> Void)?
    /// When set, the poster becomes the source of a zoom push into the detail.
    var zoomNamespace: Namespace.ID? = nil

    @Environment(RankingStore.self) private var store
    @State private var showSaveSheet = false

    var body: some View {
        HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 40)
                .zoomSource(id: movie.tmdbID, in: zoomNamespace)
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title).font(.subheadline.weight(.semibold))
                Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray)
            }
            Spacer()
            HStack(spacing: 2) {
                Button(action: onRank) {
                    Image(systemName: "plus.circle")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Rank \(movie.title)")
                Button {
                    bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
                } label: {
                    Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(store.isOnWatchlist(movie.tmdbID)
                    ? "Remove from Want to Watch" : "Save to Want to Watch")
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").foregroundStyle(Theme.gray)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .sheet(isPresented: $showSaveSheet) {
            SaveToListSheet(movie: movie)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}


/// Shimmering placeholder rows shaped like the real results, shown while
/// a search or browse fetch is in flight.
struct SearchSkeleton: View {
    enum Kind { case titles, members }
    var kind: Kind = .titles
    var rows = 8

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                row(index)
                    .padding(.vertical, 8)
                Divider()
            }
        }
        .opacity(pulse ? 0.45 : 0.9)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching")
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 12) {
            if kind == .titles {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.fill)
                    .frame(width: 40, height: 60)
            } else {
                Circle().fill(Theme.fill).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.fill)
                    .frame(width: index.isMultiple(of: 2) ? 170 : 130, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.fill)
                    .frame(width: index.isMultiple(of: 2) ? 90 : 115, height: 9)
            }
            Spacer()
            if kind == .titles {
                Circle().fill(Theme.fill).frame(width: 22, height: 22)
                Circle().fill(Theme.fill).frame(width: 22, height: 22)
            } else {
                Capsule().fill(Theme.fill).frame(width: 72, height: 30)
            }
        }
    }
}

/// Recent searches persist across launches (UserDefaults, newest first).
enum RecentSearches {
    private static let key = "cini.recentSearches"

    static func load() -> [Movie] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Movie].self, from: data)) ?? []
    }

    static func save(_ movies: [Movie]) {
        if let data = try? JSONEncoder().encode(Array(movies.prefix(10))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The import-source brand marks as app-icon-style tiles — Letterboxd's three
/// dots on a dark tile, IMDb's yellow tile, and Netflix's red "N" on black.
/// Drawn in SwiftUI (no proprietary art bundled) but faithful to the icons.
/// Used by the Swipe tab's import banner.
struct ImportSourceLogos: View {
    private let tile: CGFloat = 26
    private let radius: CGFloat = 6

    var body: some View {
        HStack(spacing: 9) {
            letterboxd
            imdb
            netflix
        }
    }

    private func tileBackground(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .frame(width: tile, height: tile)
    }

    /// Letterboxd: orange / green / blue dots on a charcoal tile.
    private var letterboxd: some View {
        tileBackground(Color(red: 0.13, green: 0.16, blue: 0.19))
            .overlay {
                HStack(spacing: 1) {
                    Circle().fill(Color(red: 1.00, green: 0.50, blue: 0.00)).frame(width: 6, height: 6)
                    Circle().fill(Color(red: 0.00, green: 0.88, blue: 0.33)).frame(width: 6, height: 6)
                    Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96)).frame(width: 6, height: 6)
                }
            }
            .accessibilityLabel("Letterboxd")
    }

    /// IMDb: black "IMDb" on the brand yellow tile.
    private var imdb: some View {
        tileBackground(Color(red: 0.96, green: 0.77, blue: 0.09))
            .overlay {
                Text("IMDb")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.5)
            }
            .accessibilityLabel("IMDb")
    }

    /// Netflix: the red "N" on a black tile.
    private var netflix: some View {
        tileBackground(.black)
            .overlay {
                Text("N")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Color(red: 0.90, green: 0.03, blue: 0.08))
            }
            .accessibilityLabel("Netflix")
    }
}
