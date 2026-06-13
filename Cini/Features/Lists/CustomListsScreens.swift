import SwiftUI

// MARK: - All of someone's lists (profile row)

struct CustomListsScreen: View {
    let userID: UUID?
    let isSelf: Bool

    @Environment(TabRouter.self) private var tabRouter
    @Environment(RankingStore.self) private var store
    @State private var lists: [CustomList] = []
    @State private var loaded = false
    @State private var newName = ""
    @State private var doomedLists: [CustomList] = []

    var body: some View {
        List {
            if isSelf {
                HStack {
                    TextField("New list", text: $newName)
                    Button("Create") {
                        Task {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty,
                                  await store.createList(name: name, mediaKind: "movie") != nil
                            else { return }
                            newName = ""
                            // Reconcile from the shared cache so the
                            // add-to-list picker sees it too.
                            lists = store.customLists
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
                Group {
                    if isSelf {
                        // Your own list opens in the Lists tab, selected —
                        // one home for your lists, never an in-profile copy.
                        Button {
                            tabRouter.pendingCustomListID = list.id
                            tabRouter.selection = .lists
                        } label: {
                            listLabel(list)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            CustomListScreen(list: list, isSelf: isSelf)
                        } label: {
                            listLabel(list)
                        }
                    }
                }
                .listRowBackground(Theme.background)
            }
            .onDelete(perform: isSelf ? { offsets in
                doomedLists = offsets.map { lists[$0] }
            } : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        // A whole list is hours of curation — deleting one confirms.
        .confirmationDialog(
            "Delete \(doomedLists.first?.name ?? "this list")?",
            isPresented: Binding(get: { !doomedLists.isEmpty },
                                 set: { if !$0 { doomedLists = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete list", role: .destructive) {
                let doomed = doomedLists
                doomedLists = []
                lists.removeAll { list in doomed.contains { $0.id == list.id } }
                Task {
                    for list in doomed {
                        await store.deleteList(list.id)
                    }
                    // The store is now authoritative — reconcile this
                    // screen so a failed delete can't leave a phantom.
                    if let userID, userID == SupabaseService.shared.currentUserID {
                        lists = store.customLists
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its movies stay on your other lists — only this list goes.")
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let userID {
                lists = (try? await SupabaseService.shared.lists(of: userID)) ?? []
            }
            loaded = true
        }
    }

    private func listLabel(_ list: CustomList) -> some View {
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
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.gray)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
    @State private var reported = false
    @State private var showBlockConfirm = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            // Public lists are UGC — moderation lives here like everywhere.
            if !isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            Task {
                                await SupabaseService.shared.report(
                                    kind: "list", subjectID: list.id.uuidString)
                                reported = true
                                ToastCenter.shared.show("Reported — we'll review it")
                            }
                        } label: {
                            Label(reported ? "Reported" : "Report this list", systemImage: "flag")
                        }
                        .disabled(reported)
                        Button(role: .destructive) {
                            showBlockConfirm = true
                        } label: {
                            Label("Block the list's owner", systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("List options")
                }
            }
        }
        .confirmationDialog("Block this list's owner?",
                            isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                Task {
                    do {
                        try await SupabaseService.shared.block(list.userId)
                        ToastCenter.shared.show("Blocked — their content is hidden everywhere")
                    } catch {
                        ToastCenter.shared.saveFailed()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's rankings, notes, lists, or activity.")
        }
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

    private var shareText: String {
        listShareText(name: list.name,
                      movies: movieIDs.compactMap { movies[$0] ?? store.movie($0) })
    }

    private func removeItems(at offsets: IndexSet) {
        let doomed = offsets.map { movieIDs[$0] }
        movieIDs.remove(atOffsets: offsets)
        Task {
            var failed = false
            for id in doomed {
                do {
                    try await SupabaseService.shared.removeFromList(list.id, movieID: id)
                } catch { failed = true }
            }
            // A swallowed failure used to "resurrect" the title on the
            // next fetch — pull the server truth back and say so.
            if failed {
                movieIDs = (try? await SupabaseService.shared.listMovieIDs(list.id)) ?? movieIDs
                ToastCenter.shared.saveFailed()
            }
        }
    }
}

// MARK: - Edit Lists (from My Lists' ellipsis menu)

/// Manage the Lists area: hide the optional default tabs, create new
/// lists, delete old ones. Watched and Want to Watch always stay.
struct EditListsSheet: View {
    @Binding var lists: [CustomList]

    @AppStorage("lists.hiddenTabs") private var hiddenTabsRaw = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(RankingStore.self) private var store
    @State private var newName = ""
    @State private var doomedLists: [CustomList] = []

    private func visibility(for tab: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenTabsRaw.split(separator: ",").map(String.init).contains(tab) },
            set: { visible in
                var hidden = Set(hiddenTabsRaw.split(separator: ",").map(String.init))
                if visible { hidden.remove(tab) } else { hidden.insert(tab) }
                hiddenTabsRaw = hidden.sorted().joined(separator: ",")
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Recs", isOn: visibility(for: "Recs"))
                    Toggle("Friend Recs", isOn: visibility(for: "Friend Recs"))
                } header: {
                    Text("Default lists")
                } footer: {
                    Text("Watched and Want to Watch are the heart of Cini — they always stay.")
                }
                .tint(Theme.marquee)

                Section {
                    HStack {
                        TextField("New list", text: $newName)
                        Button("Create") {
                            Task { await create() }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(lists) { list in
                        HStack {
                            Text(list.name)
                            Spacer()
                            Text("\(list.count)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.gray)
                        }
                    }
                    .onDelete { offsets in
                        doomedLists = offsets.map { lists[$0] }
                    }
                } header: {
                    Text("Your lists")
                } footer: {
                    Text("Swipe a list to delete it. Add movies from any movie page with \"Add to List\".")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit Lists")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete \(doomedLists.first?.name ?? "this list")?",
                isPresented: Binding(get: { !doomedLists.isEmpty },
                                     set: { if !$0 { doomedLists = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete list", role: .destructive) {
                    let doomed = doomedLists
                    doomedLists = []
                    lists.removeAll { list in doomed.contains { $0.id == list.id } }
                    Task {
                        for list in doomed {
                            await store.deleteList(list.id)
                        }
                        lists = store.customLists   // reconcile with the server truth
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its movies stay on your other lists — only this list goes.")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        if await store.createList(name: name, mediaKind: "movie") != nil {
            lists = store.customLists   // keep every surface in sync
        }
    }
}


/// "Best heist movies — my list on Cini 🎬" + the first titles.
func listShareText(name: String, movies: [Movie]) -> String {
    var lines = ["\(name) — my list on Cini 🎬"]
    for (index, movie) in movies.prefix(10).enumerated() {
        let year = movie.releaseYear.map { " (\($0))" } ?? ""
        lines.append("\(index + 1). \(movie.title)\(year)")
    }
    if movies.count > 10 {
        lines.append("…and \(movies.count - 10) more")
    }
    return lines.joined(separator: "\n")
}
