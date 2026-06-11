import SwiftUI

/// Showtimes near a zipcode — Cini's "Reserve now". Theaters with tappable
/// time chips, date switcher, and a remembered zipcode.
struct ShowtimesSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss
    @AppStorage("showtimes.zipcode") private var zipcode = ""

    @State private var date = Date()
    @State private var theaters: [TheaterShowtimes] = []
    @State private var state: LoadState = .idle

    enum LoadState {
        case idle, loading, loaded, notConfigured, error(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                content
            }
            .swipeDismissesKeyboard()
            .background(Theme.background)
            .navigationTitle("Showtimes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if zipcode.count == 5 { Task { await search() } }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location").foregroundStyle(Theme.gray)
                TextField("Zipcode", text: $zipcode)
                    .keyboardType(.numberPad)
                Button("Search") { Task { await search() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
                    .disabled(zipcode.count != 5)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))

            DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.compact)
                .onChange(of: date) { _, _ in Task { await search() } }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            placeholder(icon: "ticket", title: "Find a showing",
                        message: "Enter your zipcode to see showtimes for \(movie.title) near you.")
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notConfigured:
            placeholder(icon: "ticket", title: "Showtimes coming soon",
                        message: "Showtimes aren't enabled in this build.")
        case .error(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Couldn't load showtimes", message: message)
        case .loaded:
            if theaters.isEmpty {
                placeholder(icon: "ticket", title: "No showings",
                            message: "\(movie.title) isn't playing near \(zipcode) on this date.")
            } else {
                VStack(spacing: 0) {
                    theaterList
                    Text("Showtimes by Gracenote · tap a time to buy tickets")
                        .font(.caption2)
                        .foregroundStyle(Theme.gray)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var theaterList: some View {
        List(theaters) { theater in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(theater.theaterName).font(.subheadline.weight(.bold))
                        if !theater.address.isEmpty {
                            Text(theater.address).font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                    Spacer()
                    if let distance = theater.distanceMiles {
                        Text(String(format: "%.1f mi", distance))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                FlowingChips(showtimes: theater.showtimes)
            }
            .padding(.vertical, 6)
            .listRowBackground(Theme.background)
        }
        .listStyle(.plain)
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.gray)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func search() async {
        guard zipcode.count == 5 else { return }
        state = .loading
        do {
            theaters = try await ShowtimesService.shared.showtimes(
                for: movie, zipcode: zipcode, date: date)
            state = .loaded
        } catch ShowtimesError.notConfigured {
            state = .notConfigured
        } catch ShowtimesError.zipcodeNotFound {
            state = .error("We couldn't find that zipcode.")
        } catch {
            state = .error("Something went wrong — try again.")
        }
    }
}

/// Showtime chips wrapped onto multiple lines.
private struct FlowingChips: View {
    let showtimes: [Showtime]

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(showtimes) { showtime in
                Button {
                    if let url = showtime.bookingURL { UIApplication.shared.open(url) }
                } label: {
                    VStack(spacing: 1) {
                        Text(showtime.startTime.formatted(date: .omitted, time: .shortened))
                            .font(.caption.weight(.semibold))
                        if let format = showtime.format {
                            Text(format).font(.caption2).foregroundStyle(Theme.gray)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Theme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.marquee.opacity(0.6)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
