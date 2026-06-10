import SwiftUI
import RankingEngine

/// Post-rank enrichment — mirrors Beli's post-log screen: optional rows for
/// labels, friends, watch date, notes, favorite performances, and personal
/// notes, with "What your friends think" below.
struct EnrichmentSheet: View {
    let movie: Movie
    let scored: ScoredItem<Int>
    var onDone: () -> Void

    @Environment(RankingStore.self) private var store
    private let supabase = SupabaseService.shared

    @State private var watchDate: Date?
    @State private var notes = ""
    @State private var personalNotes = ""
    @State private var selectedLabels: Set<String> = []
    @State private var selectedCast: Set<CastMember> = []
    @State private var cast: [CastMember] = []
    @State private var friendScores: [FriendScoreRow] = []
    @State private var activeRow: Row?

    enum Row: String, Identifiable {
        case labels, friends, date, notes, performances, personalNotes
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                rankedBanner
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                enrichmentRow(.labels, icon: "tag", title: "Add Guides and Labels",
                              detail: selectedLabels.isEmpty ? nil : selectedLabels.sorted().joined(separator: ", "))
                enrichmentRow(.friends, icon: "person.2", title: "Tag friends")
                enrichmentRow(.date, icon: "calendar", title: "Add watch date",
                              detail: watchDate?.formatted(date: .abbreviated, time: .omitted))
                enrichmentRow(.notes, icon: "square.and.pencil", title: "Add Notes",
                              detail: notes.isEmpty ? nil : notes)
                enrichmentRow(.performances, icon: "star", title: "Add Favorite Performances",
                              detail: selectedCast.isEmpty ? nil : selectedCast.map(\.name).joined(separator: ", "))
                enrichmentRow(.personalNotes, icon: "eye.slash", title: "Add Personal Notes",
                              detail: personalNotes.isEmpty ? nil : "Private")
            }

            Section("What your friends think") {
                if friendScores.isEmpty {
                    Text("None of your friends have ranked \(movie.title) yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                } else {
                    ForEach(friendScores) { friend in
                        FriendThinkRow(friend: friend)
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            PillButton(title: "Done") {
                Task { await save() }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
        }
        .sheet(item: $activeRow) { row in
            rowSheet(row)
        }
        .task {
            cast = (try? await TMDBService.shared.cast(for: movie.tmdbID)) ?? []
            friendScores = (try? await supabase.friendScores(movieID: movie.tmdbID)) ?? []
        }
    }

    private var rankedBanner: some View {
        HStack(spacing: 14) {
            PosterView(url: movie.posterURL, width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ranked #\(scored.rank)").font(.headline)
                Text("on your Watched list").font(.subheadline).foregroundStyle(Theme.gray)
            }
            Spacer()
            ScoreBadge(score: scored.score)
        }
        .padding(.vertical, 8)
    }

    private func enrichmentRow(_ row: Row, icon: String, title: String, detail: String? = nil) -> some View {
        Button {
            activeRow = row
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 28)
                    .foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(Theme.gray).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowSheet(_ row: Row) -> some View {
        NavigationStack {
            switch row {
            case .labels:
                LabelPicker(selected: $selectedLabels)
            case .friends:
                Text("Tag friends you watched with")
                    .foregroundStyle(Theme.gray)
                    .navigationTitle("Tag friends")
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
        onDone()
    }
}

// MARK: - Sub-pickers

private struct LabelPicker: View {
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
        .navigationTitle("Guides and Labels")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoteEditor: View {
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

private struct CastPicker: View {
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
