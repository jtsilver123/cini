import SwiftUI

/// Shared watchlists: group lists you and friends add movies to together.
/// Lives under the "Shared" sub-tab of Your Lists.
struct SharedListsView: View {
    @State private var lists: [SharedListRow] = []
    @State private var showCreate = false
    @State private var loaded = false

    var body: some View {
        Group {
            if lists.isEmpty && loaded {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "person.2.crop.square.stack")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.gray)
                    Text("No shared lists yet").font(.headline)
                    Text("Make one for movie night, the group chat,\nor planning the next sleepover marathon.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                    PillButton(title: "New shared list", systemImage: "plus") {
                        showCreate = true
                    }
                    .padding(.top, 6)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(lists) { list in
                        NavigationLink {
                            SharedListDetailView(list: list)
                        } label: {
                            HStack(spacing: 14) {
                                Text(list.emoji).font(.title2)
                                Text(list.name).font(.headline)
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Theme.background)
                    }
                    Button {
                        showCreate = true
                    } label: {
                        Label("New shared list", systemImage: "plus")
                            .foregroundStyle(Theme.marquee)
                    }
                    .listRowBackground(Theme.background)
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateSharedListSheet { newList in
                lists.insert(newList, at: 0)
            }
            .presentationDetents([.height(300)])
        }
        .task {
            lists = (try? await SupabaseService.shared.sharedLists()) ?? []
            loaded = true
        }
    }
}

struct CreateSharedListSheet: View {
    var onCreate: (SharedListRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "🍿"

    private let emojis = ["🍿", "🎬", "❤️", "👻", "🎄", "✈️", "🍝", "🌙"]

    var body: some View {
        VStack(spacing: 18) {
            Text("New shared list").font(Theme.serif(24))
            TextField("Name (e.g. Movie Night Crew)", text: $name)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            HStack(spacing: 10) {
                ForEach(emojis, id: \.self) { option in
                    Button {
                        emoji = option
                    } label: {
                        Text(option)
                            .font(.title2)
                            .padding(8)
                            .background(Circle().fill(emoji == option ? Theme.marqueeSoft : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            PillButton(title: "Create") {
                Task {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if let list = try? await SupabaseService.shared.createSharedList(name: trimmed, emoji: emoji) {
                        onCreate(list)
                    }
                    dismiss()
                }
            }
        }
        .padding(24)
    }
}

struct SharedListDetailView: View {
    let list: SharedListRow

    @Environment(RankingStore.self) private var store
    @State private var entries: [SharedListMovieRow] = []
    @State private var members: [ProfileRow] = []
    @State private var friends: [ProfileRow] = []
    @State private var showInvite = false
    @State private var showAddMovie = false
    @State private var detailMovie: Movie?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(members) { member in
                            VStack(spacing: 4) {
                                AvatarView(url: member.avatarUrl.flatMap(URL.init), size: 44)
                                Text("@\(member.username)").font(.caption2).foregroundStyle(Theme.gray)
                            }
                        }
                        Button { showInvite = true } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .frame(width: 44, height: 44)
                                    .background(Circle().strokeBorder(Theme.marquee, style: StrokeStyle(lineWidth: 1.4, dash: [4])))
                                    .foregroundStyle(Theme.marquee)
                                Text("Invite").font(.caption2).foregroundStyle(Theme.marquee)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Theme.background)
            }

            Section {
                ForEach(entries) { entry in
                    if let movie = store.movie(entry.movieId) {
                        HStack(spacing: 12) {
                            PosterView(url: movie.posterURL, width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.title).font(.subheadline.weight(.semibold))
                                Text("added by @\(entry.profiles?.username ?? "member")")
                                    .font(.caption)
                                    .foregroundStyle(Theme.gray)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { detailMovie = movie }
                        .listRowBackground(Theme.background)
                    }
                }
                Button {
                    showAddMovie = true
                } label: {
                    Label("Add from your watchlist", systemImage: "plus")
                        .foregroundStyle(Theme.marquee)
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .background(Theme.background)
        .navigationTitle("\(list.emoji) \(list.name)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .sheet(isPresented: $showInvite) {
            invitePicker.presentationDetents([.medium])
        }
        .sheet(isPresented: $showAddMovie) {
            addMoviePicker.presentationDetents([.medium])
        }
        .task { await reload() }
    }

    private var invitePicker: some View {
        NavigationStack {
            List(friends.filter { friend in !members.contains(where: { $0.id == friend.id }) }) { friend in
                Button {
                    Task {
                        try? await SupabaseService.shared.inviteToSharedList(listID: list.id, userID: friend.id)
                        await reload()
                        showInvite = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 40)
                        Text("@\(friend.username)").foregroundStyle(Theme.ink)
                    }
                }
            }
            .navigationTitle("Invite a friend")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var addMoviePicker: some View {
        NavigationStack {
            List(store.watchlist.filter { item in !entries.contains(where: { $0.movieId == item.movieID }) }) { item in
                if let movie = store.movie(item.movieID) {
                    Button {
                        Task {
                            try? await SupabaseService.shared.addToSharedList(listID: list.id, movieID: movie.tmdbID)
                            await reload()
                            showAddMovie = false
                        }
                    } label: {
                        HStack(spacing: 12) {
                            PosterView(url: movie.posterURL, width: 36)
                            Text(movie.title).foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            .navigationTitle("Add a movie")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func reload() async {
        entries = (try? await SupabaseService.shared.sharedListMovies(listID: list.id)) ?? []
        members = (try? await SupabaseService.shared.sharedListMembers(listID: list.id)) ?? []
        friends = (try? await SupabaseService.shared.following()) ?? []
        let rows = (try? await SupabaseService.shared.movies(ids: entries.map(\.movieId))) ?? []
        for row in rows { store.cache(row.asMovie) }
    }
}
