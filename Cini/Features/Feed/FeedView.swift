import SwiftUI

struct FeedView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    @State private var events: [FeedEventRow] = []
    @State private var searchText = ""
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    searchBar
                    quickActions
                    yourFeed
                }
                .padding(.horizontal, 16)
            }
            .background(Theme.background)
            .refreshable { await loadFeed() }
            .task { await loadFeed() }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
            }
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
        }
    }

    // MARK: Header: serif wordmark + calendar / bell / hamburger

    private var header: some View {
        HStack {
            Text("cini")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.teal)
            Spacer()
            HStack(spacing: 20) {
                NavigationLink {
                    ReleaseCalendarView()
                } label: {
                    Image(systemName: "calendar")
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(.red).frame(width: 7, height: 7).offset(x: 2, y: -2)
                        }
                }
                NavigationLink {
                    NotificationsView()
                } label: {
                    Image(systemName: "bell")
                }
                Image(systemName: "line.3.horizontal")
            }
            .font(.title3)
            .foregroundStyle(Theme.ink)
        }
        .padding(.top, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
            TextField("Search a movie, member, etc.", text: $searchText)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.05)))
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                NavigationLink {
                    CiniChatView()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.subheadline.weight(.semibold))
                        Text("Ask Cini").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.teal))
                }
                .buttonStyle(.plain)
                PillButton(title: "Where to Watch", systemImage: "play.rectangle")
                PillButton(title: "Showtimes", systemImage: "ticket")
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Feed

    private var yourFeed: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YOUR FEED")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.top, 6)

            // Composer: ask friends for recs
            HStack(spacing: 12) {
                AvatarView(url: session.profile?.avatarURL, size: 44)
                Text("Ask your friends for recs")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(Color.black.opacity(0.05)))
            }

            if events.isEmpty {
                emptyState
            }

            ForEach(events) { event in
                FeedCard(
                    event: event,
                    onOpenMovie: { detailMovie = $0 },
                    onQuickAdd: { logMovie = $0 }
                )
                Divider()
            }
        }
    }

    private var emptyState: some View {
        HairlineCard {
            VStack(spacing: 8) {
                Image(systemName: "person.2").font(.title).foregroundStyle(Theme.teal)
                Text("Follow friends to fill your feed")
                    .font(.subheadline.weight(.semibold))
                Text("Search members and see what they're watching and ranking.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadFeed() async {
        events = (try? await SupabaseService.shared.feed()) ?? []
    }
}

// MARK: - Activity card

struct FeedCard: View {
    let event: FeedEventRow
    var onOpenMovie: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }

    @Environment(RankingStore.self) private var store
    @State private var liked = false
    @State private var showComments = false

    private var movie: Movie? { event.movies?.asMovie }
    private var actorName: String { event.profiles?.username ?? "someone" }

    private var headline: Text {
        let title = Text(movie?.title ?? "a movie").bold()
        switch event.eventType {
        case "ranked":
            return Text("\(actorName) ranked ") + title
        case "watchlisted":
            return Text("\(actorName) added ") + title + Text(" to their watchlist")
        case "noted":
            return Text("\(actorName) wrote about ") + title
        case "streak_milestone":
            return Text("\(actorName) hit a streak milestone 🔥")
        case "challenge_milestone":
            return Text("\(actorName) hit a challenge milestone 🏆")
        default:
            return Text("\(actorName) shared an update")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(url: event.profiles?.avatarUrl.flatMap(URL.init), size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    headline.font(.subheadline)
                    if let movie {
                        Text([movie.genres.first, movie.releaseYear.map(String.init)]
                            .compactMap(\.self).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                Spacer()
                if let movie {
                    Button { onOpenMovie(movie) } label: {
                        PosterView(url: movie.posterURL, width: 52)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 18) {
                Button {
                    liked.toggle()
                    Task { try? await SupabaseService.shared.toggleLike(eventID: event.id) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? .red : Theme.ink)
                }
                Button { showComments = true } label: {
                    Image(systemName: "bubble.right")
                }
                ShareLink(item: URL(string: "https://cini.app/movie/\(movie?.tmdbID ?? 0)")!) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(Theme.ink)
                }
                Spacer()
                if let movie {
                    Button { onQuickAdd(movie) } label: {
                        Image(systemName: "plus.circle")
                    }
                    Button {
                        Task { await store.toggleWatchlist(movie: movie) }
                    } label: {
                        Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.teal : Theme.ink)
                    }
                }
            }
            .font(.body)
            .foregroundStyle(Theme.ink)
            .buttonStyle(.plain)

            Text(event.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showComments) {
            CommentsSheet(event: event)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Comments

struct CommentsSheet: View {
    let event: FeedEventRow

    @State private var comments: [CommentRow] = []
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if comments.isEmpty && loaded {
                    Spacer()
                    Text("No comments yet — say something nice.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                    Spacer()
                } else {
                    List(comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(url: comment.profiles?.avatarUrl.flatMap(URL.init), size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("@\(comment.profiles?.username ?? "member")")
                                        .font(.caption.weight(.bold))
                                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.gray)
                                }
                                Text(comment.body).font(.subheadline)
                            }
                        }
                        .listRowBackground(Theme.background)
                    }
                    .listStyle(.plain)
                }

                HStack(spacing: 10) {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.05)))
                    Button {
                        Task { await post() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(Theme.teal)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(.thinMaterial)
            }
            .background(Theme.background)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await reload() }
    }

    private func reload() async {
        comments = (try? await SupabaseService.shared.comments(eventID: event.id)) ?? []
        loaded = true
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        draft = ""
        try? await SupabaseService.shared.comment(eventID: event.id, body: body)
        await reload()
    }
}

// MARK: - Stubs reached from the header

struct ReleaseCalendarView: View {
    @State private var upcoming: [Movie] = []

    var body: some View {
        List(upcoming) { movie in
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 44)
                VStack(alignment: .leading) {
                    Text(movie.title).font(.subheadline.weight(.semibold))
                    if let year = movie.releaseYear {
                        Text(String(year)).font(.caption).foregroundStyle(Theme.gray)
                    }
                }
            }
        }
        .navigationTitle("Release Calendar")
        .task {
            upcoming = (try? await TMDBService.shared.trending()) ?? []
        }
    }
}

struct NotificationsView: View {
    var body: some View {
        List {
            Text("Likes, comments, new followers, and friends ranking your watchlist movies show up here.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
        }
        .navigationTitle("Notifications")
    }
}
