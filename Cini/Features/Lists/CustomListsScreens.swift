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
    // A list holds one media kind — let the creator pick (Movies or TV) so a
    // TV list isn't silently forced to Movies and then hidden from the TV tab.
    @State private var newKind = "movie"
    @State private var doomedLists: [CustomList] = []
    @State private var renameTarget: CustomList?
    @State private var renameText = ""

    var body: some View {
        List {
            if isSelf {
                VStack(spacing: 10) {
                    HStack {
                        TextField("New list", text: $newName)
                        Button("Create") {
                            Task {
                                let name = newName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                guard await store.createList(name: name, mediaKind: newKind) != nil else {
                                    ToastCenter.shared.saveFailed()
                                    return
                                }
                                newName = ""
                                // Reconcile from the shared cache so the
                                // add-to-list picker sees it too.
                                lists = store.customLists
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Picker("List type", selection: $newKind) {
                        Text("Movies").tag("movie")
                        Text("TV Shows").tag("tv")
                    }
                    .pickerStyle(.segmented)
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
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if isSelf {
                        Button {
                            renameTarget = list
                            renameText = list.name
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(Theme.marquee)
                    }
                }
            }
            .onDelete(perform: isSelf ? { offsets in
                doomedLists = offsets.map { lists[$0] }
            } : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .nativeContentWidth()
        .background(Theme.background)
        // A whole list is hours of curation — deleting one confirms.
        .alert(
            "Delete \(doomedLists.first?.name ?? "this list")?",
            isPresented: Binding(get: { !doomedLists.isEmpty },
                                 set: { if !$0 { doomedLists = [] } })
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
        .alert("Rename list", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("List name", text: $renameText)
            Button("Save") {
                guard let target = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespaces)
                renameTarget = nil
                guard !name.isEmpty, name != target.name else { return }
                Task {
                    if await store.renameList(target.id, to: name) {
                        lists = store.customLists
                    }
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Pick a new name — it updates everywhere this list appears.")
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
    // Beli-style sharing: whole list vs. pick specific titles.
    @State private var showShareOptions = false
    @State private var showPickTitles = false
    @State private var sharePayload: SharePayload?

    private var listMovies: [Movie] { movieIDs.compactMap { movies[$0] ?? store.movie($0) } }

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
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShareOptions = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share list")
            }
            // Public lists are UGC — moderation lives here like everywhere.
            if !isSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            Task {
                                let ok = await SupabaseService.shared.report(
                                    kind: "list", subjectID: list.id.uuidString)
                                if ok {
                                    reported = true
                                    ToastCenter.shared.show("Reported — we'll review it")
                                } else {
                                    ToastCenter.shared.saveFailed()
                                }
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
        .alert("Block this list's owner?", isPresented: $showBlockConfirm) {
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
        // Beli-style: share the whole list, or pick specific titles.
        .confirmationDialog("How do you want to share?",
                            isPresented: $showShareOptions, titleVisibility: .visible) {
            Button("Share the whole list") {
                sharePayload = SharePayload(text: shareText(for: listMovies, whole: true))
            }
            Button("Pick titles to share") { showPickTitles = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPickTitles) {
            PickTitlesToShareSheet(listName: list.name, movies: listMovies) { picked in
                shareText(for: picked, whole: false)
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(items: [payload.text])
        }
        .task {
            movieIDs = (try? await SupabaseService.shared.listMovieIDs(list.id)) ?? []
            let rows = (try? await SupabaseService.shared.movies(ids: movieIDs)) ?? []
            for row in rows { movies[row.tmdbId] = row.asMovie }
            loaded = true
        }
    }

    /// Beli-style share text — lists the titles (whole list or a picked subset)
    /// and ends with a personal invite link so it doubles as a referral.
    private func shareText(for movies: [Movie], whole: Bool) -> String {
        var lines = [whole ? "\(list.name) — my list on Cini 🎬"
                           : "A few picks from my Cini list “\(list.name)” 🎬"]
        for (index, movie) in movies.prefix(50).enumerated() {
            let year = movie.releaseYear.map { " (\($0))" } ?? ""
            lines.append("\(index + 1). \(movie.title)\(year)")
        }
        lines.append("")
        // A private list can't be opened by others (RLS), so don't hand out a
        // dead link — share the titles + the App Store. Public lists get a link
        // that opens this exact list in the app.
        if list.isPrivate {
            lines.append(AppLinks.appStore)
        } else {
            lines.append((whole ? "Open it in Cini: " : "See the full list in Cini: ")
                         + AppLinks.listLink(list.id))
        }
        return lines.joined(separator: "\n")
    }

    private func removeItems(at offsets: IndexSet) {
        // Snapshot the exact pre-delete order so a failure or an Undo restores
        // the list precisely where it was — not reshuffled by a server refetch.
        let previous = movieIDs
        let doomed = offsets.map { movieIDs[$0] }
        withAnimation { movieIDs.remove(atOffsets: offsets) }
        Task {
            var failed = false
            for id in doomed {
                do {
                    try await SupabaseService.shared.removeFromList(list.id, movieID: id)
                } catch { failed = true }
            }
            if failed {
                // A swallowed failure used to "resurrect" the title on the next
                // fetch in some random spot. Restore the original order in place
                // and say it didn't stick, so the user keeps their bearings.
                withAnimation { movieIDs = previous }
                ToastCenter.shared.saveFailed()
            } else {
                ToastCenter.shared.showUndo(
                    doomed.count == 1 ? "Removed from list" : "Removed \(doomed.count) from list"
                ) {
                    // Bring the row(s) back instantly in their old place, then
                    // re-add server-side and reconcile to the truth.
                    withAnimation { movieIDs = previous }
                    Task {
                        for id in doomed {
                            try? await SupabaseService.shared.addToList(list.id, movieID: id)
                        }
                        movieIDs = (try? await SupabaseService.shared.listMovieIDs(list.id)) ?? previous
                    }
                }
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
    // Lists hold one media kind — let the creator choose.
    @State private var newKind = "movie"
    @State private var doomedLists: [CustomList] = []
    @State private var renameTarget: CustomList?
    @State private var renameText = ""

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
                    Picker("List type", selection: $newKind) {
                        Text("Movies").tag("movie")
                        Text("TV Shows").tag("tv")
                    }
                    .pickerStyle(.segmented)
                    ForEach(lists) { list in
                        HStack {
                            Text(list.name)
                            Spacer()
                            Text("\(list.count)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.gray)
                        }
                        // Swipe right to rename — the gentle counterpart to
                        // the destructive swipe-left delete.
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                renameTarget = list
                                renameText = list.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(Theme.marquee)
                        }
                    }
                    .onDelete { offsets in
                        doomedLists = offsets.map { lists[$0] }
                    }
                } header: {
                    Text("Your lists")
                } footer: {
                    Text("Swipe a list to rename or delete it. Add movies from any movie page with \"Add to List\".")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit Lists")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "Delete \(doomedLists.first?.name ?? "this list")?",
                isPresented: Binding(get: { !doomedLists.isEmpty },
                                     set: { if !$0 { doomedLists = [] } })
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
            .alert("Rename list", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
            ) {
                TextField("List name", text: $renameText)
                Button("Save") {
                    guard let target = renameTarget else { return }
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    renameTarget = nil
                    guard !name.isEmpty, name != target.name else { return }
                    Task {
                        if await store.renameList(target.id, to: name) {
                            lists = store.customLists   // keep every surface in sync
                        }
                    }
                }
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Pick a new name — it updates everywhere this list appears.")
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
        if await store.createList(name: name, mediaKind: newKind) != nil {
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
    lines.append(AppLinks.appStore)
    return lines.joined(separator: "\n")
}

/// Carries the text to hand to the iOS share sheet.
struct SharePayload: Identifiable {
    let id = UUID()
    let text: String
}

/// Beli's "Select places to share": a checklist of the list's titles → Share
/// only the ones you picked (as text) via the native share sheet.
private struct PickTitlesToShareSheet: View {
    let listName: String
    let movies: [Movie]
    /// Builds the share text from the picked movies.
    let buildText: ([Movie]) -> String

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var payload: SharePayload?

    var body: some View {
        NavigationStack {
            List {
                ForEach(movies) { movie in
                    let on = selected.contains(movie.tmdbID)
                    Button {
                        if on { selected.remove(movie.tmdbID) } else { selected.insert(movie.tmdbID) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(on ? Theme.marquee : Theme.gray)
                            PosterView(url: movie.posterURL, width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink).lineLimit(1)
                                if let year = movie.releaseYear {
                                    Text(String(year)).font(.caption).foregroundStyle(Theme.gray)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Pick titles to share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button {
                    payload = SharePayload(text: buildText(movies.filter { selected.contains($0.tmdbID) }))
                } label: {
                    Text(selected.isEmpty ? "Select titles to share"
                         : "Share \(selected.count) title\(selected.count == 1 ? "" : "s")")
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Capsule().fill(selected.isEmpty ? Theme.gray.opacity(0.4) : Theme.velvet))
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .sheet(item: $payload) { p in ActivityShareSheet(items: [p.text]) }
        }
    }
}
