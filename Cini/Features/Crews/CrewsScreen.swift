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

    @State private var overlap: [SupabaseService.CrewOverlapRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var loaded = false
    @State private var showAddMember = false
    @State private var planContext: WatchPlanContext?
    @State private var detailMovie: Movie?
    @State private var showLeaveConfirm = false

    private var myID: UUID? { SupabaseService.shared.currentUserID }

    /// Mutual friends not already in the crew — offered by the add picker.
    private var addableFriends: [ProfileRow] {
        let memberIDs = Set(crew.members.map(\.userId))
        return FriendsCache.shared.byTagFrequency.filter { !memberIDs.contains($0.id) }
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
                } else if overlap.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark").font(.title2).foregroundStyle(Theme.gray)
                        Text("No shared picks yet")
                            .font(.subheadline.weight(.bold))
                        Text("When two or more of you bookmark the same title, it shows up here — ready to plan.")
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
                Text("What you all want to watch")
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
        .task { await load() }
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
                ForEach(crew.members.prefix(8), id: \.userId) { member in
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
            Text(crew.members.compactMap { $0.profile.map { "@\($0.username)" } }
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
                Text("\(row.wantCount) of \(crew.members.count) want this")
                    .font(.caption)
                    .foregroundStyle(row.wantCount == crew.members.count ? Theme.scoreGreen : Theme.gray)
            }
            Spacer(minLength: 8)
            PillButton(title: "Plan it") {
                // Open the plan sheet on another member (the invite picker can
                // add the rest of the crew from the top of its list).
                guard let other = crew.members.first(where: { $0.userId != myID }),
                      let username = other.profile?.username else { return }
                planContext = WatchPlanContext(
                    movieID: row.movieId,
                    friend: MemberRef(id: other.userId, username: username))
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

    private var addMemberSheet: some View {
        NavigationStack {
            List {
                if addableFriends.isEmpty {
                    Text("Everyone you both follow is already in — follow more friends to grow the crew.")
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
                onChanged()
            } catch {
                ToastCenter.shared.saveFailed()
            }
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
        guard let rows = await SupabaseService.shared.crewOverlap(crewID: crew.id) else {
            if !Task.isCancelled, overlap.isEmpty { loaded = true }
            return
        }
        overlap = rows
        // Resolve titles: the store covers my own saves; fetch the rest.
        var byID: [Int: Movie] = [:]
        var missing: [Int] = []
        for row in rows {
            if let movie = store.movie(row.movieId) { byID[row.movieId] = movie }
            else { missing.append(row.movieId) }
        }
        if !missing.isEmpty,
           let fetched = try? await SupabaseService.shared.movies(ids: missing) {
            for row in fetched { byID[row.tmdbId] = row.asMovie }
        }
        movies = byID
        loaded = true
    }
}
