import SwiftUI

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
        // Keyed on listsRevision (like the inline Lists tab) so an add from
        // another screen — a movie page, Chat — shows up while this is open.
        .task(id: store.listsRevision) {
            // A failed fetch must not blank a populated list (or flip an
            // unloaded one to the empty state) — keep what's showing and say so.
            do {
                movieIDs = try await SupabaseService.shared.listMovieIDs(list.id)
                let rows = (try? await SupabaseService.shared.movies(ids: movieIDs)) ?? []
                for row in rows { movies[row.tmdbId] = row.asMovie }
                loaded = true
            } catch {
                if !Task.isCancelled { ToastCenter.shared.show("Couldn't load that list — check your connection.") }
            }
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
        // Guard the subscript: a concurrent listsRevision refetch can shrink the
        // array between render and this closure, so map only in-bounds offsets.
        let doomed = offsets.compactMap { movieIDs.indices.contains($0) ? movieIDs[$0] : nil }
        // Remove by the validated ids (not the raw offsets) so this matches the
        // bounds guard above and can't act on a stale offset after a refetch.
        withAnimation { movieIDs.removeAll { doomed.contains($0) } }
        Task {
            // Through the store so listsRevision bumps and other surfaces
            // refresh (it toasts on failure).
            var failed = false
            for id in doomed {
                if !(await store.removeFromList(list.id, movieID: id)) { failed = true }
            }
            if failed {
                // A swallowed failure used to "resurrect" the title on the next
                // fetch in some random spot. Restore the original order in place
                // so the user keeps their bearings.
                withAnimation { movieIDs = previous }
            } else {
                ToastCenter.shared.showUndo(
                    doomed.count == 1 ? "Removed from list" : "Removed \(doomed.count) from list"
                ) {
                    // Bring the row(s) back instantly in their old place, then
                    // re-add server-side and reconcile to the truth.
                    withAnimation { movieIDs = previous }
                    Task {
                        for id in doomed {
                            if let m = store.movie(id) { await store.addToList(list.id, movie: m) }
                            else {
                                // No cached Movie, so we can't route through the
                                // store — surface a failure rather than swallow it.
                                do { try await SupabaseService.shared.addToList(list.id, movieID: id) }
                                catch { SupabaseService.logSwallowed("undo addToList", error) }
                            }
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
    // Lists are read straight off the shared store (@Observable), so a create /
    // rename / delete here is reflected everywhere with no manual re-sync.
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
                    ForEach(store.customLists) { list in
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
                        let lists = store.customLists
                        doomedLists = offsets.compactMap { lists.indices.contains($0) ? lists[$0] : nil }
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
                    // Each delete reconciles the shared store against the server;
                    // the list above reads store.customLists, so it updates live.
                    Task {
                        for list in doomed {
                            await store.deleteList(list.id)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its titles stay on your other lists — only this list goes.")
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
                    Task { await store.renameList(target.id, to: name) }
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
        // store.createList inserts into the shared cache; the list above reads
        // store.customLists, so the new row appears with no manual re-sync.
        _ = await store.createList(name: name, mediaKind: newKind)
    }
}


/// "Best heist movies — my list on Cini 🎬" + the first titles. A public list
/// ends with a link that opens it (and renders it on the web with a rich preview
/// card); a private list can't be opened by others, so it falls back to the App
/// Store link.
func listShareText(name: String, movies: [Movie], listID: UUID? = nil, isPrivate: Bool = false) -> String {
    var lines = ["\(name) — my list on Cini 🎬"]
    for (index, movie) in movies.prefix(10).enumerated() {
        let year = movie.releaseYear.map { " (\($0))" } ?? ""
        lines.append("\(index + 1). \(movie.title)\(year)")
    }
    if movies.count > 10 {
        lines.append("…and \(movies.count - 10) more")
    }
    if let listID, !isPrivate {
        lines.append("See the full list in Cini: " + AppLinks.listLink(listID))
    } else {
        lines.append(AppLinks.appStore)
    }
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
