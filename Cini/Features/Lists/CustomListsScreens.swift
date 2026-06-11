import SwiftUI

// MARK: - Add a movie to your lists (from the movie page)

/// Toggle the movie in and out of any of your lists; create one inline.
struct AddToListSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss

    @State private var lists: [CustomList] = []
    @State private var memberOf: Set<UUID> = []
    @State private var newName = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                HStack {
                    TextField("New list (e.g. Best heist movies)", text: $newName)
                    Button("Create") {
                        Task { await createAndAdd() }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Theme.background)

                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Theme.background)
                } else if lists.isEmpty {
                    Text("Lists are your shelves — \"Date night\", \"Best of the 90s\", anything. Make one above.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .listRowBackground(Theme.background)
                }

                ForEach(lists) { list in
                    Button {
                        Task { await toggle(list) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name).foregroundStyle(Theme.ink)
                                Text("\(list.count) title\(list.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(Theme.gray)
                            }
                            Spacer()
                            Image(systemName: memberOf.contains(list.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(memberOf.contains(list.id) ? Theme.marquee : Theme.gray)
                        }
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add to List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .task {
                lists = (try? await SupabaseService.shared.myLists()) ?? []
                memberOf = await SupabaseService.shared.listIDs(containing: movie.tmdbID)
                loaded = true
            }
        }
    }

    private func toggle(_ list: CustomList) async {
        if memberOf.contains(list.id) {
            memberOf.remove(list.id)
            do { try await SupabaseService.shared.removeFromList(list.id, movieID: movie.tmdbID) }
            catch { memberOf.insert(list.id) }
        } else {
            memberOf.insert(list.id)
            do { try await SupabaseService.shared.addToList(list.id, movieID: movie.tmdbID) }
            catch { memberOf.remove(list.id) }
        }
    }

    private func createAndAdd() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let list = try? await SupabaseService.shared.createList(name: name) else { return }
        newName = ""
        lists.insert(list, at: 0)
        memberOf.insert(list.id)
        try? await SupabaseService.shared.addToList(list.id, movieID: movie.tmdbID)
    }
}

// MARK: - All of someone's lists (profile row)

struct CustomListsScreen: View {
    let userID: UUID?
    let isSelf: Bool

    @State private var lists: [CustomList] = []
    @State private var loaded = false
    @State private var newName = ""

    var body: some View {
        List {
            if isSelf {
                HStack {
                    TextField("New list", text: $newName)
                    Button("Create") {
                        Task {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty,
                                  let list = try? await SupabaseService.shared.createList(name: name)
                            else { return }
                            newName = ""
                            lists.insert(list, at: 0)
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Theme.background)
            }

            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.background)
            } else if lists.isEmpty {
                Text(isSelf ? "No lists yet — make your first above, then add movies from any movie page."
                            : "No public lists yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .listRowBackground(Theme.background)
            }

            ForEach(lists) { list in
                NavigationLink {
                    CustomListScreen(list: list, isSelf: isSelf)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "list.star")
                            .font(.title3)
                            .foregroundStyle(Theme.marquee)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.name).font(.headline).foregroundStyle(Theme.ink)
                            Text("\(list.count) title\(list.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.background)
            }
            .onDelete(perform: isSelf ? deleteLists : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let userID {
                lists = (try? await SupabaseService.shared.lists(of: userID)) ?? []
            }
            loaded = true
        }
    }

    private func deleteLists(at offsets: IndexSet) {
        let doomed = offsets.map { lists[$0] }
        lists.remove(atOffsets: offsets)
        Task {
            for list in doomed {
                try? await SupabaseService.shared.deleteList(list.id)
            }
        }
    }
}

// MARK: - One list's movies

struct CustomListScreen: View {
    let list: CustomList
    let isSelf: Bool

    @Environment(RankingStore.self) private var store

    @State private var movieIDs: [Int] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var loaded = false
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?

    var body: some View {
        List {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.background)
            } else if movieIDs.isEmpty {
                Text(isSelf ? "Empty so far — add movies with \"Add to List\" on any movie page."
                            : "Nothing on this list yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .listRowBackground(Theme.background)
            }
            ForEach(movieIDs, id: \.self) { id in
                if let movie = movies[id] ?? store.movie(id) {
                    WatchlistRowView(movie: movie) {
                        logMovie = movie
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.cache(movie)
                        detailMovie = movie
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .onDelete(perform: isSelf ? removeItems : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
        .task {
            movieIDs = (try? await SupabaseService.shared.listMovieIDs(list.id)) ?? []
            let rows = (try? await SupabaseService.shared.movies(ids: movieIDs)) ?? []
            for row in rows { movies[row.tmdbId] = row.asMovie }
            loaded = true
        }
    }

    private func removeItems(at offsets: IndexSet) {
        let doomed = offsets.map { movieIDs[$0] }
        movieIDs.remove(atOffsets: offsets)
        Task {
            for id in doomed {
                try? await SupabaseService.shared.removeFromList(list.id, movieID: id)
            }
        }
    }
}
