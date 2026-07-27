import SwiftUI

/// Crews — a small group of friends with one shared "what should WE watch"
/// view. The overlap of members' Want to Watch lists is the ballot: every
/// bookmark is a vote, no separate voting machinery. Start a crew, add
/// mutual friends, and turn the strongest overlap into a movie night.
struct CrewsHomeScreen: View {
    @State private var crews: [SupabaseService.CrewRow] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var showCreate = false
    @State private var newName = ""
    @State private var creating = false
    @State private var loadKey = 0

    var body: some View {
        Group {
            if !loaded {
                ListSkeleton(rows: 3)
                    .screenHPadding()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
            } else if loadFailed && crews.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.slash").font(.title2).foregroundStyle(Theme.gray)
                    Text("Couldn't load your crews")
                        .font(.subheadline.weight(.bold))
                    PillButton(title: "Try again") { loadKey += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if crews.isEmpty {
                emptyState
            } else {
                crewList
            }
        }
        .background(Theme.background)
        .navigationTitle("Crews")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showCreate) { createSheet }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.3.fill").font(.largeTitle).foregroundStyle(Theme.gold)
            Text("Start a crew")
                .font(Theme.serif(26))
            Text("A crew is your movie-night group. Everyone's Want to Watch combines into one list — the titles you ALL want rise to the top, ready to plan.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            PillButton(title: "Start a crew", systemImage: "plus") { showCreate = true }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var crewList: some View {
        List {
            ForEach(crews) { crew in
                NavigationLink {
                    CrewScreen(crew: crew, onChanged: { loadKey += 1 })
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(Theme.gold)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.fill))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(crew.name).font(.subheadline.weight(.bold))
                            Text("\(crew.members.count) member\(crew.members.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.background)
            }
            Button {
                showCreate = true
            } label: {
                Label("Start another crew", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
            }
            .listRowBackground(Theme.background)
        }
        .listStyle(.plain)
    }

    private var createSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name your crew")
                    .font(Theme.serif(24))
                Text("Roommates, film club, the group chat — whoever you actually watch with.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                TextField("e.g. Friday Night Crew", text: $newName)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                Spacer()
                PillButton(title: creating ? "Creating…" : "Create crew", style: .filled) {
                    createCrew()
                }
                .disabled(creating || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("New crew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreate = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createCrew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                _ = try await SupabaseService.shared.crewCreate(name: name)
                Haptics.success()
                newName = ""
                showCreate = false
                loadKey += 1
            } catch {
                ToastCenter.shared.saveFailed()
            }
        }
    }

    private func load() async {
        // Keep prior crews on a failed fetch — never blank a populated list.
        if let fresh = await SupabaseService.shared.myCrews() {
            crews = fresh
            loadFailed = false
        } else if !Task.isCancelled {
            loadFailed = true
        }
        loaded = true
    }
}

/// One crew: the roster plus the shared ballot (titles 2+ members want).
struct CrewScreen: View {
    let crew: SupabaseService.CrewRow
    var onChanged: () -> Void = {}

    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The LIVE roster. Seeded from the passed-in crew, then refreshed after
    /// every add — the passed value is a snapshot from the list screen, so
    /// reading it directly left the avatars, the names line, and every
    /// "N of M want this" denominator stale right after adding someone.
    @State private var members: [SupabaseService.CrewMemberRow] = []
    @State private var overlap: [SupabaseService.CrewOverlapRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var loaded = false
    /// The overlap fetch failed — show a retry, never "no shared picks yet"
    /// (a crew with ten picks must not be told it has none).
    @State private var loadFailed = false
    @State private var showAddMember = false
    @State private var planContext: WatchPlanContext?
    @State private var detailMovie: Movie?
    @State private var showLeaveConfirm = false
    @State private var loadKey = 0
    /// Mutual-follow ids (they follow me back) — the server's own bar for
    /// crew_add_member. nil until loaded, so the picker can show a skeleton
    /// instead of claiming everyone's already in.
    @State private var mutualIDs: Set<UUID>?

    private var myID: UUID? { SupabaseService.shared.currentUserID }

    /// Mutual friends not already in the crew — the exact set the server will
    /// accept, so no row in this picker can fail with "not mutuals".
    private var addableFriends: [ProfileRow] {
        guard let mutualIDs else { return [] }
        let memberIDs = Set(members.map(\.userId))
        return FriendsCache.shared.byTagFrequency.filter {
            !memberIDs.contains($0.id) && mutualIDs.contains($0.id)
        }
    }

    var body: some View {
        List {
            membersHeader
                .listRowSeparator(.hidden)
                .listRowBackground(Theme.background)

            Section {
                if !loaded {
                    ListSkeleton(rows: 4)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                } else if loadFailed && overlap.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.slash").font(.title2).foregroundStyle(Theme.gray)
                        Text("Couldn't load this crew's picks")
                            .font(.subheadline.weight(.bold))
                        PillButton(title: "Try again") { loadKey += 1 }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                } else if overlap.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark").font(.title2).foregroundStyle(Theme.gray)
                        Text("No shared picks yet")
                            .font(.subheadline.weight(.bold))
                        Text(members.count <= 1
                             ? "Add a friend — the titles you both bookmark show up here, ready to plan."
                             : "When two or more of you bookmark the same title, it shows up here — ready to plan.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
                } else {
                    ForEach(overlap, id: \.movieId) { row in
                        overlapRow(row)
                            .listRowBackground(Theme.background)
                    }
                }
            } header: {
                Text(members.count <= 1 ? "On your Want to Watch" : "What you all want to watch")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.gray)
            }
        }
        .listStyle(.plain)
        .background(Theme.background)
        .navigationTitle(crew.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAddMember = true } label: {
                        Label("Add a friend", systemImage: "person.badge.plus")
                    }
                    Button(role: .destructive) { showLeaveConfirm = true } label: {
                        Label("Leave crew", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showAddMember) { addMemberSheet }
        .sheet(item: $planContext) { ctx in
            PlanWatchSheet(context: ctx)
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .alert("Leave \(crew.name)?", isPresented: $showLeaveConfirm) {
            Button("Leave crew", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can be added back by any member. If you're the last one out, the crew is deleted.")
        }
    }

    private var membersHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: -8) {
                ForEach(members.prefix(8), id: \.userId) { member in
                    AvatarView(url: (member.profile?.avatarUrl).flatMap(URL.init), size: 38,
                               name: preferredName(member.profile?.displayName,
                                                   member.profile?.username))
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                }
                Button { showAddMember = true } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.marquee)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.fill))
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a friend to the crew")
            }
            Text(members.compactMap { $0.profile.map { "@\($0.username)" } }
                    .joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }

    private func overlapRow(_ row: SupabaseService.CrewOverlapRow) -> some View {
        HStack(spacing: 12) {
            PosterView(url: movies[row.movieId]?.posterURL, width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(movies[row.movieId]?.title ?? "…")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(2)
                Text(members.count <= 1
                     ? "On your Want to Watch"
                     : "\(row.wantCount) of \(members.count) want this")
                    .font(.caption)
                    .foregroundStyle(members.count > 1 && row.wantCount == members.count
                                     ? Theme.scoreGreen : Theme.gray)
            }
            Spacer(minLength: 8)
            // A one-person crew has nobody to plan with — offer the action that
            // actually moves things forward instead of a button that no-ops.
            if let target = planTarget(for: row) {
                PillButton(title: "Plan it") {
                    planContext = WatchPlanContext(movieID: row.movieId, friend: target)
                }
            } else {
                PillButton(title: "Add a friend", style: .outlined) { showAddMember = true }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let movie = movies[row.movieId] {
                store.cache(movie)
                detailMovie = movie
            }
        }
    }

    /// Who to open the plan sheet on: someone who actually bookmarked this
    /// title (the row's own wanters), else any other member. nil for a
    /// one-person crew, where "Plan it" would have nobody to invite.
    private func planTarget(for row: SupabaseService.CrewOverlapRow) -> MemberRef? {
        let others = members.filter { $0.userId != myID }
        let wanters = Set(row.memberUsernames)
        let pick = others.first { $0.profile.map { wanters.contains($0.username) } ?? false }
            ?? others.first
        guard let pick, let username = pick.profile?.username else { return nil }
        return MemberRef(id: pick.userId, username: username)
    }

    private var addMemberSheet: some View {
        NavigationStack {
            List {
                if mutualIDs == nil {
                    // Mutuals still resolving — a skeleton, not a claim that
                    // there's nobody to add.
                    ListSkeleton(rows: 4)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                } else if addableFriends.isEmpty {
                    Text("Everyone who follows you back is already in this crew — follow more friends to grow it.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .listRowBackground(Theme.background)
                } else {
                    ForEach(addableFriends) { friend in
                        Button {
                            add(friend)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 36,
                                           name: preferredName(friend.displayName, friend.username))
                                Text("@\(friend.username)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Theme.marquee)
                            }
                        }
                        .listRowBackground(Theme.background)
                    }
                }
            }
            .listStyle(.plain)
            .background(Theme.background)
            .navigationTitle("Add to \(crew.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showAddMember = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(_ friend: ProfileRow) {
        Task {
            do {
                try await SupabaseService.shared.crewAddMember(crewID: crew.id, userID: friend.id)
                Haptics.success()
                ToastCenter.shared.show("Added @\(friend.username) to \(crew.name)")
                showAddMember = false
                // Refresh the roster on THIS screen too — the parent list
                // reload doesn't reach the pushed screen the user is looking at.
                await refreshMembers()
                onChanged()
            } catch {
                // The server's caps and trust rules deserve real explanations;
                // a bare "couldn't save" leaves the user retrying forever.
                let message = "\(error)"
                if message.contains("crew full") {
                    ToastCenter.shared.show("A crew holds up to 8 people.")
                } else if message.contains("crew limit") {
                    ToastCenter.shared.show("@\(friend.username) is already in 5 crews — their limit.")
                } else if message.contains("not mutuals") {
                    ToastCenter.shared.show("You can only add friends who follow you back.")
                } else {
                    ToastCenter.shared.saveFailed()
                }
            }
        }
    }

    /// Re-read this crew's roster (after an add) so the avatars, the names
    /// line, and every "N of M" denominator match reality immediately.
    private func refreshMembers() async {
        guard let fresh = await SupabaseService.shared.myCrews()?
            .first(where: { $0.id == crew.id }) else { return }
        members = fresh.members
        // Denominators changed — the ballot's thresholds did too.
        if let rows = await SupabaseService.shared.crewOverlap(crewID: crew.id) {
            overlap = rows
            await resolveTitles(rows)
        }
    }

    private func leave() {
        Task {
            do {
                try await SupabaseService.shared.crewLeave(crewID: crew.id)
                onChanged()
                dismiss()
            } catch {
                ToastCenter.shared.saveFailed()
            }
        }
    }

    private func load() async {
        FriendsCache.shared.refreshIfStale()   // powers the add picker
        if members.isEmpty { members = crew.members }   // seed from the snapshot
        // Only offer people the server will actually accept (mutuals).
        if mutualIDs == nil {
            let following = await SupabaseService.shared.followingIDs()
            let followers = await SupabaseService.shared.followerIDs()
            mutualIDs = following.intersection(followers)
        }
        guard let rows = await SupabaseService.shared.crewOverlap(crewID: crew.id) else {
            // Keep whatever's on screen; flag the failure so an empty screen
            // offers a retry instead of claiming there are no shared picks.
            if !Task.isCancelled {
                loadFailed = true
                loaded = true
            }
            return
        }
        loadFailed = false
        overlap = rows
        await resolveTitles(rows)
        loaded = true
    }

    /// Fill in posters/titles for the ballot — my own saves come from the
    /// shared store, other members' need a fetch.
    private func resolveTitles(_ rows: [SupabaseService.CrewOverlapRow]) async {
        var byID: [Int: Movie] = [:]
        var missing: [Int] = []
        for row in rows {
            if let movie = store.movie(row.movieId) { byID[row.movieId] = movie }
            else { missing.append(row.movieId) }
        }
        if !missing.isEmpty {
            do {
                for row in try await SupabaseService.shared.movies(ids: missing) {
                    byID[row.tmdbId] = row.asMovie
                }
            } catch {
                // Don't swallow silently: without titles these rows render as
                // "…" and don't open, and the cause would be invisible.
                SupabaseService.logSwallowed("crewOverlapMovies", error)
            }
        }
        movies = byID
    }
}
