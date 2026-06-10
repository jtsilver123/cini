import SwiftUI
import RankingEngine

/// Post-rank enrichment card — bottom of the log-flow stack, mirroring
/// Beli: "Who did you watch with?" chips, labels, notes, favorite
/// performances, watch date, personal notes, a Stealth-mode toggle that
/// keeps the rank off the feed, and a single Okay to finish.
struct EnrichmentCard: View {
    let movie: Movie
    let scored: ScoredItem<Int>
    var onDone: () -> Void

    @Environment(RankingStore.self) private var store
    private let supabase = SupabaseService.shared

    @State private var friends: [ProfileRow] = []
    @State private var watchedWith: Set<UUID> = []
    @State private var watchDate: Date?
    @State private var notes = ""
    @State private var personalNotes = ""
    @State private var selectedLabels: Set<String> = []
    @State private var selectedCast: Set<CastMember> = []
    @State private var cast: [CastMember] = []
    @State private var friendScores: [FriendScoreRow] = []
    @State private var stealthMode = false
    @State private var activeRow: Row?

    enum Row: String, Identifiable {
        case labels, date, notes, performances, personalNotes
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            rankedBanner
                .padding(.bottom, 6)

            watchedWithSection
            divider
            enrichmentRow(.labels, icon: "tag", title: "Add labels (date night, etc.)",
                          detail: selectedLabels.isEmpty ? nil : selectedLabels.sorted().joined(separator: ", "))
            divider
            enrichmentRow(.notes, icon: "square.and.pencil", title: "Add notes",
                          detail: notes.isEmpty ? nil : notes)
            divider
            enrichmentRow(.performances, icon: "star", title: "Add favorite performances",
                          detail: selectedCast.isEmpty ? nil : selectedCast.map(\.name).joined(separator: ", "))
            divider
            enrichmentRow(.date, icon: "calendar", title: "Add watch date",
                          detail: watchDate?.formatted(date: .abbreviated, time: .omitted))
            divider
            enrichmentRow(.personalNotes, icon: "eye.slash", title: "Add personal notes",
                          detail: personalNotes.isEmpty ? nil : "Private")
            divider
            stealthRow

            if !friendScores.isEmpty {
                divider
                friendsSection
            }

            Button {
                Task { await save() }
            } label: {
                Text("Okay")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.teal)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .floatingCard()
        .sheet(item: $activeRow) { row in
            rowSheet(row)
        }
        .task {
            friends = (try? await supabase.following()) ?? []
            cast = (try? await TMDBService.shared.cast(for: movie.tmdbID)) ?? []
            friendScores = (try? await supabase.friendScores(movieID: movie.tmdbID)) ?? []
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.hairline)
    }

    private var rankedBanner: some View {
        HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ranked #\(scored.rank)").font(.headline)
                Text("on your Watched list").font(.subheadline).foregroundStyle(Theme.gray)
            }
            Spacer()
            ScoreBadge(score: scored.score, size: 48)
        }
        .padding(.bottom, 8)
    }

    // MARK: Who did you watch with?

    private var watchedWithSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "person.2").frame(width: 28)
                Text("Who did you watch with?")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            if !friends.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(friends) { friend in
                            let isOn = watchedWith.contains(friend.id)
                            Button {
                                if isOn { watchedWith.remove(friend.id) } else { watchedWith.insert(friend.id) }
                            } label: {
                                Text(friend.displayName.isEmpty ? friend.username : friend.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(isOn ? .white : Theme.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isOn ? Theme.teal : Color.black.opacity(0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(.vertical, 12)
    }

    private func enrichmentRow(_ row: Row, icon: String, title: String, detail: String? = nil) -> some View {
        Button {
            activeRow = row
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 28).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var stealthRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock").frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Stealth mode")
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.teal)
                }
                Text("Hide this activity from the feed")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
            Spacer()
            Toggle("", isOn: $stealthMode).labelsHidden().tint(Theme.teal)
        }
        .padding(.vertical, 10)
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What your friends think")
                .font(.headline)
                .padding(.top, 12)
            ForEach(friendScores.prefix(3)) { friend in
                FriendThinkRow(friend: friend)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Row sheets

    @ViewBuilder
    private func rowSheet(_ row: Row) -> some View {
        NavigationStack {
            switch row {
            case .labels:
                LabelPicker(selected: $selectedLabels)
            case .date:
                DatePicker(
                    "Watch date",
                    selection: Binding(get: { watchDate ?? .now }, set: { watchDate = $0 }),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Watch date")
            case .notes:
                NoteEditor(title: "Notes", subtitle: "Visible to your friends", text: $notes)
            case .performances:
                CastPicker(cast: cast, selected: $selectedCast)
            case .personalNotes:
                NoteEditor(title: "Personal Notes", subtitle: "Only you can see these", text: $personalNotes)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        if !notes.isEmpty {
            try? await supabase.upsertNote(movieID: movie.tmdbID, body: notes, isPrivate: false)
        }
        if !personalNotes.isEmpty {
            try? await supabase.upsertNote(movieID: movie.tmdbID, body: personalNotes, isPrivate: true)
        }
        for member in selectedCast {
            try? await supabase.addPerformance(movieID: movie.tmdbID, cast: member)
        }
        if !watchedWith.isEmpty || watchDate != nil {
            try? await supabase.updateRanking(movieID: movie.tmdbID,
                                              watchedWith: Array(watchedWith),
                                              watchDate: watchDate)
        }
        if stealthMode {
            try? await supabase.hideRankEvent(movieID: movie.tmdbID)
        }
        onDone()
    }
}

// MARK: - Sub-pickers

struct LabelPicker: View {
    @Binding var selected: Set<String>

    private let builtIns = ["Date Night", "Plane Movie", "Mindblower", "Slow Burn",
                            "Rewatchable", "Comfort Watch", "Tearjerker", "Popcorn Flick"]
    @State private var custom = ""

    var body: some View {
        List {
            ForEach(builtIns + selected.subtracting(builtIns).sorted(), id: \.self) { label in
                Button {
                    if selected.contains(label) { selected.remove(label) } else { selected.insert(label) }
                } label: {
                    HStack {
                        Text(label).foregroundStyle(Theme.ink)
                        Spacer()
                        if selected.contains(label) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.teal)
                        }
                    }
                }
            }
            HStack {
                TextField("New label", text: $custom)
                Button("Add") {
                    let name = custom.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    selected.insert(name)
                    custom = ""
                }
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Labels")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NoteEditor: View {
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle).font(.caption).foregroundStyle(Theme.gray)
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            Spacer()
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CastPicker: View {
    let cast: [CastMember]
    @Binding var selected: Set<CastMember>

    var body: some View {
        List(cast) { member in
            Button {
                if selected.contains(member) { selected.remove(member) } else { selected.insert(member) }
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: member.photoURL, size: 40)
                    VStack(alignment: .leading) {
                        Text(member.name).foregroundStyle(Theme.ink)
                        if let character = member.character {
                            Text(character).font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                    Spacer()
                    if selected.contains(member) {
                        Image(systemName: "checkmark").foregroundStyle(Theme.teal)
                    }
                }
            }
        }
        .navigationTitle("Favorite Performances")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Friend row with avatar, username, score badge, notes, like + comment.
struct FriendThinkRow: View {
    let friend: FriendScoreRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName ?? friend.username).font(.subheadline.weight(.semibold))
                    Text("@\(friend.username)").font(.caption).foregroundStyle(Theme.gray)
                }
                Spacer()
                ScoreBadge(score: friend.score, size: 44)
            }
            if let note = friend.note, !note.isEmpty {
                (Text("Notes: ").bold() + Text(note))
                    .font(.subheadline)
            }
            HStack(spacing: 18) {
                Image(systemName: "heart")
                Image(systemName: "bubble.right")
            }
            .font(.body)
            .foregroundStyle(Theme.ink)
            Text(friend.rankedAt.formatted(.dateTime.month(.wide).year()))
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
        .padding(.vertical, 6)
    }
}
