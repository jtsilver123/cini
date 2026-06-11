import SwiftUI

/// "Log a rewatch" — Beli's "Rank a new visit": a quick diary entry with
/// a date and where you watched, without touching your ranking.
struct RewatchSheet: View {
    let movie: Movie
    var onLogged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var location: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log a rewatch").font(Theme.serif(22))
                    Text(movie.title).font(.caption).foregroundStyle(Theme.gray)
                }
                Spacer()
            }

            DatePicker("Watched on", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.compact)
                .tint(Theme.marquee)

            HStack(spacing: 8) {
                locationChip("At home", icon: "house", value: "home")
                locationChip("In theaters", icon: "ticket", value: "theater")
                Spacer()
            }

            PillButton(title: saving ? "Saving…" : "Save to diary") {
                guard !saving else { return }
                saving = true
                Task {
                    do {
                        try await SupabaseService.shared.logWatch(
                            movieID: movie.tmdbID, on: date, where: location)
                        Haptics.success()
                        ToastCenter.shared.show("Added to your Diary")
                        onLogged()
                    } catch {
                        ToastCenter.shared.saveFailed()
                    }
                    dismiss()
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(saving)

            Text("Rewatches stack up in your Diary — your rank and score stay put.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(20)
        .background(Theme.background)
    }

    private func locationChip(_ title: String, icon: String, value: String) -> some View {
        let isOn = location == value
        return Button {
            location = isOn ? nil : value
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.subheadline)
            }
            .foregroundStyle(isOn ? Theme.background : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Theme.marquee : Theme.fill))
        }
        .buttonStyle(.plain)
    }
}
