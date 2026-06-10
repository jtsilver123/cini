import SwiftUI
import RankingEngine

/// Details card — appears right after "How was it?", before comparisons
/// (Beli's order): who you watched with, labels, notes, favorite
/// performances, watch date, personal notes, Stealth mode, then Okay to
/// move on to the head-to-head. Inputs collect into an EnrichmentDraft
/// the flow persists after the rank commits.
struct EnrichmentCard: View {
    let movie: Movie
    @Binding var draft: EnrichmentDraft
    /// True once comparisons begin — inputs stay visible but read-only.
    var isLocked = false
    var onOkay: () -> Void

    private let supabase = SupabaseService.shared

    @State private var friends: [ProfileRow] = []
    @State private var cast: [CastMember] = []
    @State private var friendScores: [FriendScoreRow] = []
    @State private var activeRow: Row?

    enum Row: String, Identifiable {
        case labels, date, notes, performances, personalNotes
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            watchedWithSection
            divider
            enrichmentRow(.labels, icon: "tag", title: "Add labels (date night, etc.)",
                          detail: draft.labels.isEmpty ? nil : draft.labels.sorted().joined(separator: ", "))
            divider
            enrichmentRow(.notes, icon: "square.and.pencil", title: "Add notes",
                          detail: draft.notes.isEmpty ? nil : draft.notes)
            divider
            enrichmentRow(.performances, icon: "star", title: "Add favorite performances",
                          detail: draft.cast.isEmpty ? nil : draft.cast.map(\.name).joined(separator: ", "))
            divider
            enrichmentRow(.date, icon: "calendar", title: "Add watch date",
                          detail: draft.watchDate?.formatted(date: .abbreviated, time: .omitted))
            divider
            enrichmentRow(.personalNotes, icon: "eye.slash", title: "Add personal notes",
                          detail: draft.personalNotes.isEmpty ? nil : "Private")
            divider
            stealthRow

            if !friendScores.isEmpty {
                divider
                friendsSection
            }

            if !isLocked {
                Button {
                    onOkay()
                } label: {
                    Text("Okay")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.teal)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, isLocked ? 10 : 0)
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

    // MARK: Who did you watch with?

    private var watchedWithSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "person.2").frame(width: 28)
                Text("Who did you watch with?")
                Spacer()
            }
            if !friends.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(friends) { friend in
                            let isOn = draft.watchedWith.contains(friend.id)
                            Button {
                                guard !isLocked else { return }
                                if isOn { draft.watchedWith.remove(friend.id) }
                                else { draft.watchedWith.insert(friend.id) }
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
            } else {
                Text("Follow friends to tag them here.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
        }
        .padding(.vertical, 12)
    }

    private func enrichmentRow(_ row: Row, icon: String, title: String, detail: String? = nil) -> some View {
        Button {
            guard !isLocked else { return }
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
                Text("Stealth mode")
                Text("Hide this activity from the feed")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
            Spacer()
            Toggle("", isOn: $draft.stealthMode).labelsHidden().tint(Theme.teal)
                .disabled(isLocked)
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
                LabelPicker(selected: $draft.labels)
            case .date:
                DatePicker(
                    "Watch date",
                    selection: Binding(get: { draft.watchDate ?? .now }, set: { draft.watchDate = $0 }),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Watch date")
            case .notes:
                NoteEditor(title: "Notes", subtitle: "Visible to your friends", text: $draft.notes)
            case .performances:
                CastPicker(cast: cast, selected: $draft.cast)
            case .personalNotes:
                NoteEditor(title: "Personal Notes", subtitle: "Only you can see these", text: $draft.personalNotes)
            }
        }
        .presentationDetents([.medium, .large])
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
