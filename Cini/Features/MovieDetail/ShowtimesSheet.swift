import SwiftUI

/// Showtimes near a zipcode — Cini's "Reserve now". Theaters with tappable
/// time chips, date switcher, and a remembered zipcode.
struct ShowtimesSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss
    @AppStorage("showtimes.zipcode") private var zipcode = ""

    var initialDate: Date? = nil
    @State private var date = Date()
    @State private var theaters: [TheaterShowtimes] = []
    @State private var state: LoadState = .idle
    @State private var isLocating = false

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
            if let initialDate, initialDate > Date() { date = initialDate }
            if zipcode.count == 5 { Task { await search() } }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    Task { await fillFromLocation() }
                } label: {
                    if isLocating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "location.fill").foregroundStyle(Theme.marquee)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLocating)
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
                    Text("Showtimes by Gracenote · $ = bargain pricing · tickets open in Fandango")
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(theater.theaterName).font(.subheadline.weight(.bold))
                    if !theater.amenities.isEmpty {
                        // The closest thing showtime data has to seat info.
                        Text(theater.amenities.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.marquee)
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

    /// Tap the location glyph: permission → position → zipcode → search.
    private func fillFromLocation() async {
        isLocating = true
        defer { isLocating = false }
        do {
            zipcode = try await LocationZip.shared.currentZip()
            await search()
        } catch LocationZip.LocationError.denied {
            state = .error("Location is off for Cini — allow it in Settings, or type your zipcode.")
        } catch {
            state = .error("Couldn't pin down your location — type your zipcode instead.")
        }
    }

    private func search() async {
        guard zipcode.count == 5 else { return }
        state = .loading
        do {
            theaters = try await ShowtimesService.shared.showtimes(
                for: movie, zipcode: zipcode, date: date)
            state = .loaded
            // Remember the zip — it powers "your watchlist movie is
            // playing near you" push alerts.
            await SupabaseService.shared.setHomeZip(zipcode)
        } catch ShowtimesError.notConfigured {
            state = .notConfigured
        } catch ShowtimesError.zipcodeNotFound {
            state = .error("We couldn't find that zipcode.")
        } catch {
            state = .error("Something went wrong — try again.")
        }
    }
}

/// Showtime chips wrapped onto multiple lines. Past times dim, the next
/// upcoming showing glows, "$" marks bargain pricing, and tapping opens
/// the Fandango app directly when it's installed.
private struct FlowingChips: View {
    let showtimes: [Showtime]

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 8)]

    /// The first showing that hasn't started yet — tonight's obvious pick.
    private var nextUp: Showtime? {
        showtimes.first { $0.startTime > Date() }
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(showtimes) { showtime in
                let isPast = showtime.startTime <= Date()
                let isNext = showtime.id == nextUp?.id
                Button {
                    if let url = showtime.bookingURL { openTickets(url) }
                } label: {
                    VStack(spacing: 1) {
                        Text(chipTitle(showtime))
                            .font(.caption.weight(.semibold))
                        if let format = showtime.format {
                            Text(format).font(.caption2)
                                .foregroundStyle(isNext ? Theme.ink.opacity(0.8) : Theme.gray)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Theme.ink)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(isNext ? Theme.marquee.opacity(0.18) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(showtime.bookingURL == nil || isPast
                                      ? Theme.hairline
                                      : Theme.marquee.opacity(isNext ? 1 : 0.6),
                                      lineWidth: isNext ? 1.4 : 1))
                    .opacity(isPast ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                // Started already, or no ticket link from the provider —
                // show the time as info, not a button that goes nowhere.
                .disabled(showtime.bookingURL == nil || isPast)
            }
        }
    }

    private func chipTitle(_ showtime: Showtime) -> String {
        let time = showtime.startTime.formatted(date: .omitted, time: .shortened)
        return showtime.isBargain ? "\(time) · $" : time
    }

    /// Universal-link first: lands in the Fandango app when it's
    /// installed, falls back to the browser when it isn't.
    private func openTickets(_ url: URL) {
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened {
                UIApplication.shared.open(url)
            }
        }
    }
}
