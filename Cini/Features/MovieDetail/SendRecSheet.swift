import SwiftUI

/// Send this movie to a specific friend, with an optional note.
struct SendRecSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss

    @State private var friends: [ProfileRow] = []
    @State private var selected: ProfileRow?
    @State private var note = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errorMessage: String?
    @State private var loaded = false

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
            friends = (try? await SupabaseService.shared.following()) ?? []
            loaded = true
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // What's being sent
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title).font(.subheadline.weight(.bold))
                    Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if friends.isEmpty && loaded {
                VStack(spacing: 8) {
                    Image(systemName: "person.2").font(.title).foregroundStyle(Theme.gray)
                    Text("Follow friends first")
                        .font(.subheadline.weight(.semibold))
                    Text("Recs go to people you follow — find them in Search → Members.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(friends) { friend in
                            friendRow(friend)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Note + send pinned at the bottom
            VStack(spacing: 10) {
                TextField("Add a note (optional) — why they'll love it", text: $note, axis: .vertical)
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
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(selected == nil ? Theme.gray.opacity(0.4) : Theme.velvet))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || sending)
            }
            .padding(12)
            .background(.thinMaterial)
        }
    }

    private func friendRow(_ friend: ProfileRow) -> some View {
        Button {
            selected = selected?.id == friend.id ? nil : friend
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName.isEmpty ? friend.username : friend.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("@\(friend.username)").font(.caption).foregroundStyle(Theme.gray)
                }
                Spacer()
                Image(systemName: selected?.id == friend.id ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected?.id == friend.id ? Theme.marquee : Theme.gray)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sentState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.marquee)
            Text("Sent!").font(Theme.serif(28))
            if let selected {
                Text("@\(selected.username) just got your rec for \(movie.title).")
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
        guard let selected else { return }
        errorMessage = nil
        sending = true
        defer { sending = false }
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
