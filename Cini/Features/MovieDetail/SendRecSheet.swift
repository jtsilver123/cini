import SwiftUI

/// Send this movie to a specific friend, with an optional note.
struct SendRecSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss
    @Environment(TabRouter.self) private var tabRouter

    @State private var friendsCache = FriendsCache.shared
    @State private var selected: ProfileRow?
    @State private var note = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errorMessage: String?
    @State private var loaded = false
    /// Friends who've already ranked this title — you can't rec something
    /// they've already seen (CIN-35).
    @State private var seenByFriendIDs: Set<UUID> = []

    @State private var query = ""

    /// Cache-first: friends you tag most show first, instantly.
    private var friends: [ProfileRow] { friendsCache.byTagFrequency }

    /// Friends filtered by the search box — matches name OR username.
    private var filteredFriends: [ProfileRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return friends }
        return friends.filter {
            $0.username.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sent {
                    sentState
                } else {
                    content
                }
            }
            .background(Theme.background)
            .navigationTitle("Recommend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if friendsCache.following.isEmpty {
                await friendsCache.refresh()
            } else {
                friendsCache.refreshIfStale()
            }
            // Who's already ranked this? Those friends can't be rec'd it.
            if let scores = try? await SupabaseService.shared.friendScores(movieID: movie.tmdbID) {
                seenByFriendIDs = Set(scores.map(\.userId))
            }
            loaded = true
        }
    }

    private func hasSeen(_ friend: ProfileRow) -> Bool { seenByFriendIDs.contains(friend.id) }

    private var content: some View {
        VStack(spacing: 0) {
            // What's being sent
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title).font(.subheadline.weight(.bold)).lineLimit(2).minimumScaleFactor(0.85)
                    Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if !loaded && friends.isEmpty {
                ListSkeleton(rows: 5)
                    .padding(16)
            } else if friends.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2").font(.title).foregroundStyle(Theme.gray)
                    Text("Follow friends first")
                        .font(.subheadline.weight(.semibold))
                    Text("Recs go to people you follow.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                    PillButton(title: "Find members", systemImage: "magnifyingglass", style: .outlined) {
                        dismiss()
                        tabRouter.openMembersSearch = true
                        tabRouter.selection = .search
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // Search a specific friend by name or @username (CIN-23).
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                    TextField("Search friends", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredFriends) { friend in
                            friendRow(friend)
                            Divider()
                        }
                        if filteredFriends.isEmpty {
                            Text("No friends match \"\(query)\"")
                                .font(.subheadline)
                                .foregroundStyle(Theme.gray)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            // Note + send pinned at the bottom
            VStack(spacing: 10) {
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    .onChange(of: note) { _, new in note = String(new.prefix(280)) }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Theme.scoreRed)
                }
                Button {
                    Task { await send() }
                } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(.white) }
                        Text(selected.map { "Send to @\($0.username)" } ?? "Pick a friend")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    // Disabled state needs a solid fill + muted text — white on a
                    // pale 0.4 gray was near-illegible in light mode.
                    .foregroundStyle(selected == nil ? Theme.gray : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(selected == nil ? Theme.surface2 : Theme.velvet))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || sending)
            }
            .padding(12)
            .background(.thinMaterial)
        }
    }

    private func friendRow(_ friend: ProfileRow) -> some View {
        let seen = hasSeen(friend)
        return Button {
            guard !seen else { return }
            selected = selected?.id == friend.id ? nil : friend
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 42,
                           name: friend.displayName.isEmpty ? friend.username : friend.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(firstName(friend.displayName, friend.username) ?? friend.username)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("@\(friend.username)").font(.caption).foregroundStyle(Theme.gray)
                        .lineLimit(1)
                }
                Spacer()
                if seen {
                    // Already ranked it — can't be recommended this title.
                    Text("Already ranked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                } else {
                    Image(systemName: selected?.id == friend.id ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected?.id == friend.id ? Theme.marquee : Theme.gray)
                }
            }
            .padding(.vertical, 8)
            .opacity(seen ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(seen)
    }

    private var sentState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.marquee)
            Text("Sent!").font(Theme.serif(28))
            if let selected {
                Text("\(firstName(selected.displayName, selected.username) ?? selected.username) just got your rec for \(movie.title).")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func send() async {
        guard let selected, !sending else { return }
        // Defensive: never send a rec for something they've already seen.
        guard !seenByFriendIDs.contains(selected.id) else {
            errorMessage = "\(firstName(selected.displayName, selected.username) ?? selected.username) has already seen this."
            return
        }
        errorMessage = nil
        sending = true
        defer { sending = false }
        // direct_recs references movies — make sure this one is cached.
        do { try await SupabaseService.shared.cacheMovie(movie) }
        catch { SupabaseService.logSwallowed("send_rec_cache_movie", error) }
        let ok = await SupabaseService.shared.sendDirectRec(
            to: selected.id, movieID: movie.tmdbID, note: note)
        if ok {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.snappy) { sent = true }
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
        } else {
            errorMessage = "Couldn't send — check your connection and try again."
        }
    }
}
