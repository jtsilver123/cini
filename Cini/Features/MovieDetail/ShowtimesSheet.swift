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
    @State private var searchingNext = false
    @State private var noNextFound = false
    /// Screen-type filter (nil = every screen). Options come from the loaded
    /// results, so the row only offers formats actually playing nearby.
    @State private var screenFormat: String?
    /// Set true to skip the re-search that a programmatic date change would
    /// otherwise trigger (we already have the showtimes for the new date).
    @State private var suppressSearch = false

    enum LoadState {
        case idle, loading, loaded, notConfigured, error(String)
    }

    /// Distinct premium formats in the loaded results ("IMAX", "Dolby", …),
    /// headline formats first so IMAX doesn't hide behind 3D.
    private var availableFormats: [String] {
        let order = ["IMAX", "Dolby Atmos", "Dolby", "4DX", "ScreenX",
                     "RPX", "70mm", "Laser", "3D"]
        let found = Set(theaters.flatMap { $0.showtimes.compactMap(\.format) })
        return order.filter(found.contains) + found.subtracting(order).sorted()
    }

    /// Theaters trimmed to the selected screen type; theaters left with no
    /// matching showings drop out entirely.
    private var filteredTheaters: [TheaterShowtimes] {
        guard let screenFormat else { return theaters }
        return theaters.compactMap { theater in
            let times = theater.showtimes.filter { $0.format == screenFormat }
            guard !times.isEmpty else { return nil }
            return TheaterShowtimes(id: theater.id, theaterName: theater.theaterName,
                                    amenities: theater.amenities, showtimes: times)
        }
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
                .accessibilityLabel("Use my location")
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
                .onChange(of: date) { _, _ in
                    if suppressSearch { suppressSearch = false; return }
                    Task { await search() }
                }

            // Screen type — only offered when a premium format is actually
            // playing nearby (a standard-only town gets no dead pills).
            if case .loaded = state, !availableFormats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(title: "All screens", hasChevron: false,
                                   active: screenFormat == nil) {
                            Haptics.tap()
                            screenFormat = nil
                            noNextFound = false
                        }
                        ForEach(availableFormats, id: \.self) { format in
                            FilterPill(title: format, hasChevron: false,
                                       active: screenFormat == format) {
                                Haptics.tap()
                                screenFormat = screenFormat == format ? nil : format
                                noNextFound = false
                            }
                        }
                    }
                }
            }
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
                        message: "Showtimes aren't available right now.")
        case .error(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Couldn't load showtimes", message: message)
        case .loaded:
            if theaters.isEmpty {
                noShowingsView
            } else if filteredTheaters.isEmpty, let screenFormat {
                // The filter emptied the list — say so instead of showing the
                // generic zero state (the pills above stay tappable to switch),
                // and offer the next date WITH that screen type.
                VStack(spacing: 10) {
                    placeholder(icon: "sparkles.tv",
                                title: "No \(screenFormat) showings",
                                message: "\(movie.title) isn't playing in \(screenFormat) near \(zipcode) on this date.")
                    if noNextFound {
                        Text("No \(screenFormat) showings in the next two weeks either — try another screen type.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 24)
                    } else {
                        Button {
                            Task { await findNextAvailable() }
                        } label: {
                            HStack(spacing: 6) {
                                if searchingNext { ProgressView().controlSize(.small).tint(.white) }
                                Text(searchingNext ? "Searching…" : "Find the next \(screenFormat) date")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(Capsule().fill(Theme.velvet))
                        }
                        .buttonStyle(.plain)
                        .disabled(searchingNext)
                        .padding(.bottom, 24)
                    }
                }
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
        List(filteredTheaters) { theater in
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(theater.theaterName).font(.subheadline.weight(.bold)).lineLimit(2)
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

    /// No showings on this date — offer to jump to the next date that has any.
    private var noShowingsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "ticket").font(.largeTitle).foregroundStyle(Theme.gray)
            Text("No showings").font(.headline)
            Text("\(movie.title) isn't playing near \(zipcode) on this date.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if noNextFound {
                Text("Nothing in the next two weeks either — try another zipcode.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Button {
                    Task { await findNextAvailable() }
                } label: {
                    HStack(spacing: 6) {
                        if searchingNext { ProgressView().controlSize(.small).tint(.white) }
                        Text(searchingNext ? "Searching…" : "Find the next date with showtimes")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(Theme.velvet))
                }
                .buttonStyle(.plain)
                .disabled(searchingNext)
                .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Probe forward day-by-day (up to two weeks) for the first date with any
    /// showings, then jump the picker there.
    private func findNextAvailable() async {
        guard zipcode.count == 5 else { return }
        searchingNext = true
        defer { searchingNext = false }
        let cal = Calendar.current
        var probe = cal.startOfDay(for: date)
        for _ in 0..<14 {
            probe = cal.date(byAdding: .day, value: 1, to: probe) ?? probe
            do {
                // An empty result is "no showings that day" → keep probing; a
                // thrown error is a real failure (network/config) → stop, don't
                // hammer the API 14 times on an outage.
                let found = try await ShowtimesService.shared.showtimes(
                    for: movie, zipcode: zipcode, date: probe)
                // Honor an active screen filter: someone hunting IMAX wants
                // the next date WITH an IMAX showing, not just any showing.
                let matches = screenFormat == nil ? !found.isEmpty
                    : found.contains { theater in
                        theater.showtimes.contains { $0.format == screenFormat }
                    }
                if matches {
                    suppressSearch = true   // we already have this date's showtimes
                    date = probe
                    theaters = found
                    state = .loaded
                    return
                }
            } catch {
                // A real failure (network/config) — say so, rather than
                // claiming there's nothing playing for two weeks.
                state = .error("Couldn't check upcoming dates — try again.")
                return
            }
        }
        noNextFound = true
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
        noNextFound = false
        state = .loading
        do {
            theaters = try await ShowtimesService.shared.showtimes(
                for: movie, zipcode: zipcode, date: date)
            state = .loaded
            // A screen filter carries across dates while it still applies;
            // if the new date has no such screenings, fall back to all
            // screens rather than an instantly-empty list.
            if let format = screenFormat, !availableFormats.contains(format) {
                screenFormat = nil
            }
            // Remember the zip — it powers "your watchlist movie is
            // playing near you" push alerts. Best-effort here (the user came
            // for showtimes, which loaded), but leave a trace on failure.
            do { try await SupabaseService.shared.setHomeZip(zipcode) }
            catch { SupabaseService.logSwallowed("setHomeZip", error) }
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
