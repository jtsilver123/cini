import SwiftUI

// Ask friends for a rec (and answer their asks). The request carries
// optional type/genre/note; answers ride the existing direct-rec
// pipeline, so they land in the requester's Friend Recs with the note.

/// Requester side: multi-select friends, optionally narrow the ask.
/// With a pinned recipient (a friend's profile button) the picker is
/// skipped — the ask goes to them.
struct RequestRecsSheet: View {
    var recipientID: UUID?
    var recipientUsername: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(TabRouter.self) private var tabRouter

    @State private var friendsCache = FriendsCache.shared
    @State private var selected: Set<UUID>
    @State private var mediaKind: String?     // nil = any, "movie", "tv"
    @State private var genre: String?         // nil = any
    @State private var note = ""
    @State private var sending = false

    init(recipientID: UUID? = nil, recipientUsername: String? = nil) {
        self.recipientID = recipientID
        self.recipientUsername = recipientUsername
        _selected = State(initialValue: recipientID.map { Set([$0]) } ?? [])
    }

    private static let genres = [
        "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary",
        "Drama", "Family", "Fantasy", "History", "Horror", "Music", "Mystery",
        "Romance", "Science Fiction", "Thriller", "War", "Western",
    ]

    private var friends: [ProfileRow] { friendsCache.byTagFrequency }

    var body: some View {
        NavigationStack {
            Group {
                if friends.isEmpty && recipientID == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2").font(.title).foregroundStyle(Theme.gray)
                        Text("Follow some friends first — recs come from people you follow.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .multilineTextAlignment(.center)
                        PillButton(title: "Find friends", systemImage: "person.badge.plus") {
                            dismiss()
                            tabRouter.openMembersSearch = true
                            tabRouter.selection = .search
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(Theme.background)
            .navigationTitle("Ask for Recs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { friendsCache.refreshIfStale() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let recipientUsername, recipientID != nil {
                        (Text("Asking ") + Text("@\(recipientUsername)").bold()
                            + Text(" for a rec"))
                            .font(.subheadline)
                    } else {
                        section("WHO TO ASK")
                        VStack(spacing: 0) {
                            ForEach(friends) { friend in
                                friendRow(friend)
                                Divider()
                            }
                        }
                    }

                    section("WHAT KIND OF THING? (OPTIONAL)")
                    HStack(spacing: 8) {
                        typeChip("Anything", value: nil)
                        typeChip("Movies", value: "movie")
                        typeChip("TV shows", value: "tv")
                    }
                    Menu {
                        Button("Any genre") { genre = nil }
                        ForEach(Self.genres, id: \.self) { name in
                            Button(name) { genre = name }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(genre ?? "Genre")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(genre == nil ? Theme.ink : Theme.background)
                        .background(Capsule().fill(genre == nil ? Theme.fill : Theme.marquee))
                    }

                    section("ADD A NOTE (OPTIONAL)")
                    TextField("e.g. something for movie night with my sister", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                }
                .padding(16)
            }
            sendBar
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.gray)
    }

    private func friendRow(_ friend: ProfileRow) -> some View {
        let isOn = selected.contains(friend.id)
        return Button {
            Haptics.tap()
            if isOn { selected.remove(friend.id) } else { selected.insert(friend.id) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 38,
                           name: preferredName(friend.displayName, friend.username))
                VStack(alignment: .leading, spacing: 1) {
                    Text(firstName(friend.displayName, friend.username) ?? friend.username)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("@\(friend.username)").font(.caption).foregroundStyle(Theme.gray)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Theme.marquee : Theme.gray)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func typeChip(_ title: String, value: String?) -> some View {
        let isOn = mediaKind == value
        return Button {
            mediaKind = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(isOn ? Theme.background : Theme.ink)
                .background(Capsule().fill(isOn ? Theme.marquee : Theme.fill))
        }
        .buttonStyle(.plain)
    }

    private var sendButtonTitle: String {
        if sending { return "Sending…" }
        if let recipientUsername, recipientID != nil { return "Ask @\(recipientUsername)" }
        if selected.isEmpty { return "Ask friends" }
        return "Ask \(selected.count) friend\(selected.count == 1 ? "" : "s")"
    }

    private var sendBar: some View {
        VStack(spacing: 0) {
            Divider()
            PillButton(
                title: sendButtonTitle,
                systemImage: "paperplane"
            ) {
                guard !selected.isEmpty, !sending else { return }
                sending = true
                Task {
                    let count = await SupabaseService.shared.requestRecs(
                        to: Array(selected), mediaKind: mediaKind, genre: genre,
                        note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                    sending = false
                    if count > 0 {
                        ToastCenter.shared.show("Asked \(count) friend\(count == 1 ? "" : "s") for a rec 🎬")
                        dismiss()
                    } else {
                        ToastCenter.shared.show("Couldn't send that — try again")
                    }
                }
            }
            .padding(16)
            .disabled(selected.isEmpty || sending)
            .opacity(selected.isEmpty ? 0.5 : 1)
        }
        .background(Theme.background)
    }
}

/// Responder side: each pending ask leads to a multi-select of your own
/// ranked titles — every pick lands as a direct rec.
struct RespondRecSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var requests: [RecRequestRow] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if requests.isEmpty && loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.title).foregroundStyle(Theme.gray)
                        Text("All caught up — no open rec requests.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(requests) { request in
                            NavigationLink {
                                RespondPickerView(
                                    request: request,
                                    onFulfilled: { fulfilled in
                                        requests.removeAll { $0.id == fulfilled }
                                        if requests.isEmpty { dismiss() }
                                    },
                                    closeSheet: { dismiss() }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("**\(firstName(request.profiles?.displayName, request.profiles?.username) ?? "someone")** wants \(request.criteriaText)")
                                        .font(.subheadline)
                                    if let note = request.note {
                                        Text("“\(note)”").font(.caption).italic()
                                            .foregroundStyle(Theme.gray)
                                            .lineLimit(3)
                                    }
                                    Text(request.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2).foregroundStyle(Theme.gray)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Theme.background)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background)
            .navigationTitle("Rec Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            requests = (try? await SupabaseService.shared.incomingRecRequests()) ?? []
            loaded = true
        }
    }
}

/// Multi-select your ranked titles for one request; Send fires a direct
/// rec per pick and fulfills the ask.
struct RespondPickerView: View {
    let request: RecRequestRow
    var onFulfilled: (UUID) -> Void
    /// Closes the whole sheet (dismiss() here only pops the push).
    var closeSheet: () -> Void = {}

    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<Int> = []
    @State private var note = ""
    @State private var sending = false

    private var allWatched: [Movie] {
        var all: [Movie] = []
        for item in store.watchedItems {
            if let movie = store.movie(item.id) { all.append(movie) }
        }
        return all
    }

    private var matchingAsk: [Movie] {
        var filtered = allWatched
        if request.mediaKind == "tv" { filtered = filtered.filter { $0.mediaKind == "tv" } }
        if request.mediaKind == "movie" { filtered = filtered.filter { $0.mediaKind != "tv" } }
        if let genre = request.genre {
            filtered = filtered.filter { movie in
                movie.genres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
            }
        }
        return filtered
    }

    /// Titles matching the ask; falls back to everything when the
    /// filters leave nothing (better than a dead end).
    private var candidates: [Movie] {
        let matching = matchingAsk
        return matching.isEmpty ? allWatched : matching
    }

    private var filtersMissed: Bool {
        (request.genre != nil || request.mediaKind != nil)
            && matchingAsk.isEmpty && !allWatched.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("**\(firstName(request.profiles?.displayName, request.profiles?.username) ?? "someone")** wants \(request.criteriaText)")
                    .font(.subheadline).lineLimit(2)
                if let askNote = request.note {
                    Text("“\(askNote)”").font(.caption).italic().foregroundStyle(Theme.gray)
                        .lineLimit(3)
                }
                if filtersMissed {
                    Text("Nothing you've ranked matches exactly — showing everything.")
                        .font(.caption).foregroundStyle(Theme.gray)
                }
                TextField("Add a note (optional)", text: $note)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            if candidates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film").font(.title).foregroundStyle(Theme.gray)
                    Text("Rank a few titles first — recs come from what you've watched.")
                        .font(.subheadline).foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                    PillButton(title: "Rank something", systemImage: "plus") {
                        closeSheet()
                        tabRouter.selection = .search
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(candidates) { movie in
                        candidateRow(movie)
                            .listRowBackground(Theme.background)
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
            }
            sendBar
        }
        .background(Theme.background)
        .navigationTitle("Pick your recs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func candidateRow(_ movie: Movie) -> some View {
        let isOn = picked.contains(movie.tmdbID)
        return Button {
            Haptics.tap()
            if isOn { picked.remove(movie.tmdbID) } else { picked.insert(movie.tmdbID) }
        } label: {
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink).lineLimit(2)
                    Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
                }
                Spacer()
                if let scored = store.scoredItem(for: movie.tmdbID) {
                    Text(String(format: "%.1f", scored.score))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.scoreGreen)
                }
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Theme.marquee : Theme.gray)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sendBar: some View {
        VStack(spacing: 0) {
            Divider()
            PillButton(
                title: sending
                    ? "Sending…"
                    : "Send \(picked.isEmpty ? "recs" : "\(picked.count) rec\(picked.count == 1 ? "" : "s")")",
                systemImage: "paperplane"
            ) {
                guard !picked.isEmpty, !sending else { return }
                sending = true
                Task {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    var sent = 0
                    for movieID in picked {
                        guard let movie = store.movie(movieID) else { continue }
                        // direct_recs FKs onto movies — cache first.
                        do { try await SupabaseService.shared.cacheMovie(movie) }
                        catch { SupabaseService.logSwallowed("send_rec_cache_movie", error) }
                        if await SupabaseService.shared.sendDirectRec(
                            to: request.requesterId, movieID: movieID, note: trimmed) {
                            sent += 1
                        }
                    }
                    if sent > 0 {
                        // The recs are sent either way; completion is
                        // bookkeeping — if it fails, leave the ask
                        // visible so it can be cleared later.
                        let completed = await SupabaseService.shared.completeRecRequest(id: request.id)
                        ToastCenter.shared.show("Sent \(sent) rec\(sent == 1 ? "" : "s") to @\(request.profiles?.username ?? "them") 🎬")
                        sending = false
                        if completed { onFulfilled(request.id) }
                        dismiss()
                    } else {
                        sending = false
                        ToastCenter.shared.show("Couldn't send — try again")
                    }
                }
            }
            .padding(16)
            .disabled(picked.isEmpty || sending)
            .opacity(picked.isEmpty ? 0.5 : 1)
        }
        .background(Theme.background)
    }
}
