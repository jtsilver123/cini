import SwiftUI

/// Showtimes near a zipcode — Cini's "Reserve now". Theaters with tappable
/// time chips, date switcher, and a remembered zipcode.
struct ShowtimesSheet: View {
    let movie: Movie

    @Environment(\.dismiss) private var dismiss
    @AppStorage("showtimes.zipcode") private var zipcode = ""
    /// Search radius in miles — remembered like the zipcode.
    @AppStorage("showtimes.radius") private var radius = 15

    var initialDate: Date? = nil
    @State private var date = Date()
    @State private var theaters: [TheaterShowtimes] = []
    @State private var state: LoadState = .idle
    @State private var isLocating = false
    @State private var searchingNext = false
    @State private var noNextFound = false
    /// Screen-type filter (nil = every screen). The menu always offers the
    /// full format set, sectioned by what's actually playing nearby.
    @State private var screenFormat: String?
    /// The sheet opens pre-filtered to a PREFERRED screen (Settings → Viewing
    /// preferences) when one is actually playing — once per open, so clearing
    /// or changing it afterwards is never fought.
    @State private var didAutoSelectFormat = false
    /// Seat-comfort filter (nil = any seats) — matches against the
    /// theatre-level amenities Gracenote exposes.
    @State private var seatFilter: String?
    /// Set true to skip the re-search that a programmatic date change would
    /// otherwise trigger (we already have the showtimes for the new date).
    @State private var suppressSearch = false
    /// Graphical calendar for dates beyond the two-week chip row.
    @State private var showDatePicker = false
    /// What the user is TYPING — committed to the shared `zipcode` only on
    /// Search, so half-typed digits never clobber the saved ZIP app-wide.
    @State private var zipInput = ""
    /// Monotonic stamp for in-flight searches: only the LATEST may commit.
    /// Without it, a slow Friday response can land after a fast Saturday one
    /// and show Friday's showtimes under a selected Saturday chip.
    @State private var searchGen = 0
    /// Day chips scale with Dynamic Type instead of clipping their labels.
    @ScaledMetric(relativeTo: .subheadline) private var chipSize: CGFloat = 52

    enum LoadState {
        case idle, loading, loaded, notConfigured, error(String)
    }

    private let cal = Calendar.current

    /// The next two weeks as tappable day chips (theater-app style); when the
    /// selected date is beyond them (a far-off release, or a "find the next
    /// IMAX date" jump), it joins the row so the selection is always visible.
    private var chipDates: [Date] {
        let today = cal.startOfDay(for: Date())
        var days = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let selected = cal.startOfDay(for: date)
        if !days.contains(where: { cal.isDate($0, inSameDayAs: selected) }) {
            days.append(selected)
        }
        return days
    }

    /// Distinct premium formats in the loaded results ("IMAX", "Dolby", …),
    /// headline formats first so IMAX doesn't hide behind 3D.
    private var availableFormats: [String] {
        let order = ["IMAX", "Dolby Atmos", "Dolby", "4DX", "ScreenX",
                     "RPX", "70mm", "Laser", "3D"]
        let found = Set(theaters.flatMap { $0.showtimes.compactMap(\.format) })
        return order.filter(found.contains) + found.subtracting(order).sorted()
    }

    /// Every screen type worth asking for. The menu ALWAYS offers the full
    /// set — split into what's playing near you on this date vs the rest —
    /// so "is there IMAX?" is answered by reading the menu, never by a
    /// missing option. Picking one that isn't nearby lands on the "No IMAX
    /// showings → find the next IMAX date" flow.
    private static let allFormats = ["IMAX", "Dolby Atmos", "Dolby", "4DX",
                                     "ScreenX", "RPX", "70mm", "3D", "Laser"]

    /// Formats in the menu beyond what's playing nearby: the full standard
    /// set, plus any oddball format Gracenote reported that we don't list.
    private var otherFormats: [String] {
        Self.allFormats.filter { !availableFormats.contains($0) }
    }

    /// Theaters trimmed to the selected screen type and seat filter;
    /// theaters left with no matching showings drop out entirely.
    private var filteredTheaters: [TheaterShowtimes] {
        theaters.compactMap { theater in
            if let seatFilter, !theater.amenities.contains(seatFilter) { return nil }
            guard let screenFormat else { return theater }
            let times = theater.showtimes.filter { $0.format == screenFormat }
            guard !times.isEmpty else { return nil }
            return TheaterShowtimes(id: theater.id, theaterName: theater.theaterName,
                                    amenities: theater.amenities, showtimes: times)
        }
    }

    /// "IMAX", "Recliners", or "IMAX · Recliners" — what the active filters
    /// mean in copy ("No IMAX showings", "Find the next IMAX date").
    private var activeFilterLabel: String? {
        let parts = [screenFormat, seatFilter].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One row of the Screen menu — checkmarked when it's the active filter.
    private func screenOption(_ title: String, _ value: String?) -> some View {
        Button {
            screenFormat = value
            noNextFound = false
        } label: {
            if screenFormat == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// One row of the Seats menu — checkmarked when it's the active filter.
    private func seatOption(_ title: String, _ value: String?) -> some View {
        Button {
            seatFilter = value
            noNextFound = false
        } label: {
            if seatFilter == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Does this theater satisfy the active screen + seat filters?
    private func matchesFilters(_ theater: TheaterShowtimes) -> Bool {
        if let seatFilter, !theater.amenities.contains(seatFilter) { return false }
        guard let screenFormat else { return !theater.showtimes.isEmpty }
        return theater.showtimes.contains { $0.format == screenFormat }
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
            zipInput = zipcode
            if let initialDate, initialDate > Date() {
                // The assignment fires the date onChange too — suppress its
                // search so opening on a future date fetches ONCE, not twice.
                if zipcode.count == 5 { suppressSearch = true }
                date = initialDate
            }
            if zipcode.count == 5 { Task { await search() } }
        }
        .sheet(isPresented: $showDatePicker) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showDatePicker = false }
                        .font(.body.weight(.semibold))
                        .padding([.top, .trailing], 16)
                }
                datePickerBody
            }
        }
    }

    private var datePickerBody: some View {
            DatePicker("Date", selection: $date,
                       in: cal.startOfDay(for: Date())...,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.marquee)
                .padding()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .onChange(of: date) { _, _ in showDatePicker = false }
    }

    /// One tappable day — "TODAY / 17" style, gold when selected.
    private func dayChip(_ day: Date) -> some View {
        let selected = cal.isDate(day, inSameDayAs: date)
        let label = cal.isDateInToday(day) ? "TODAY"
            : day.formatted(.dateTime.weekday(.abbreviated)).uppercased()
        return Button {
            guard !selected else { return }
            Haptics.tap()
            date = day
        } label: {
            VStack(spacing: 2) {
                Text(label).font(.caption2.weight(.bold))
                Text(day.formatted(.dateTime.day()))
                    .font(.subheadline.weight(.bold))
            }
            .frame(width: chipSize, height: chipSize)
            .foregroundStyle(selected ? Theme.onMarquee : Theme.ink)
            .background(RoundedRectangle(cornerRadius: Theme.rControl)
                .fill(selected ? Theme.marquee : Theme.fill))
        }
        .buttonStyle(.plain)
        .id(day)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day())
                            + (selected ? ", selected" : ""))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            // The film this sheet is about — grounds the sheet at a glance.
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(movie.title)
                        .font(Theme.serif(20))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text([movie.releaseYear.map(String.init), movie.runtimeText,
                          movie.genres.first]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
                Spacer()
            }

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
                TextField("ZIP code", text: $zipInput)
                    .keyboardType(.numberPad)
                Button("Search") {
                    zipcode = zipInput.filter(\.isNumber)
                    Task { await search() }
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
                    .disabled(zipInput.filter(\.isNumber).count != 5)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.rControl).fill(Theme.fill))

            // Day chips (theater-app style): the next two weeks one tap away,
            // the calendar button for anything further out.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chipDates, id: \.self) { day in dayChip(day) }
                        Button {
                            showDatePicker = true
                        } label: {
                            Image(systemName: "calendar")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.marquee)
                                .frame(width: 44, height: chipSize)
                                .background(RoundedRectangle(cornerRadius: Theme.rControl)
                                    .strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pick another date")
                    }
                }
                // The strip is HORIZONTAL-only: pin its height to the chips
                // and kill vertical bounce, so a slightly-vertical drag can't
                // wiggle the row up and down (it read as broken scrolling).
                .frame(height: chipSize)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .onChange(of: date) { _, newValue in
                    // One-tick defer: a far-future date APPENDS its chip in
                    // this same update — scrolling immediately targets a row
                    // that doesn't exist yet and parks the strip on today.
                    Task { @MainActor in
                        withAnimation(.snappy) {
                            proxy.scrollTo(cal.startOfDay(for: newValue), anchor: .center)
                        }
                    }
                    if suppressSearch { suppressSearch = false; return }
                    Task { await search() }
                }
            }

            // Filters — same dropdown-pill UI as the list filter bar:
            // Distance (re-searches), Screen type, Seats. The Screen menu
            // always offers the FULL format set, sectioned by what's playing
            // near you on this date — so the options are explicit, and
            // picking a not-nearby one flows into "find the next IMAX date".
            if case .loaded = state {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Menu {
                            Section("Distance from \(zipcode.isEmpty ? "you" : zipcode)") {
                                ForEach([5, 10, 15, 25, 50], id: \.self) { miles in
                                    Button {
                                        guard radius != miles else { return }
                                        radius = miles
                                        Task { await search() }
                                    } label: {
                                        if radius == miles {
                                            Label("\(miles) miles", systemImage: "checkmark")
                                        } else {
                                            Text("\(miles) miles")
                                        }
                                    }
                                }
                            }
                        } label: {
                            FilterPill(title: "\(radius) mi", active: radius != 15)
                        }
                        Menu {
                            screenOption("Any screen", nil)
                            if !availableFormats.isEmpty {
                                Section("Playing near you") {
                                    ForEach(availableFormats, id: \.self) { screenOption($0, $0) }
                                }
                            }
                            if !otherFormats.isEmpty {
                                Section(availableFormats.isEmpty
                                        ? "Screen types"
                                        : "Not nearby on this date") {
                                    ForEach(otherFormats, id: \.self) { screenOption($0, $0) }
                                }
                            }
                        } label: {
                            FilterPill(title: screenFormat ?? "Screen type",
                                       active: screenFormat != nil)
                        }
                        Menu {
                            seatOption("Any seats", nil)
                            Section("Seat type") {
                                seatOption("Recliners", "Recliners")
                                seatOption("Reserved seating", "Reserved seating")
                            }
                        } label: {
                            FilterPill(title: seatFilter ?? "Seats", active: seatFilter != nil)
                        }
                    }
                }
                // Same treatment as the day strip: horizontal only, no
                // vertical give under a diagonal drag.
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            }
        }
        .screenHPadding()
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            placeholder(icon: "ticket", title: "Find a showing",
                        message: "Enter your ZIP code to see showtimes for \(movie.title) near you.")
        case .loading:
            // Skeleton, not a blank spinner — the shape of what's coming.
            ScrollView {
                ListSkeleton(rows: 4)
                    .screenHPadding()
                    .padding(.top, 4)
            }
            .scrollDisabled(true)
        case .notConfigured:
            placeholder(icon: "ticket", title: "Showtimes coming soon",
                        message: "Showtimes aren't available right now.")
        case .error(let message):
            placeholder(icon: "exclamationmark.triangle", title: "Couldn't load showtimes", message: message)
        case .loaded:
            if theaters.isEmpty {
                noShowingsView
            } else if filteredTheaters.isEmpty, let filterLabel = activeFilterLabel {
                // The filters emptied the list — say so instead of showing the
                // generic zero state (the pills above stay tappable to switch),
                // and offer the next date that matches them.
                VStack(spacing: 0) {
                    Spacer()
                    EmptyStateView(
                        icon: "sparkles.tv",
                        title: "No \(filterLabel) showings",
                        message: "\(movie.title) isn't playing near \(zipcode) with these filters on this date."
                            + (isFarFuture ? " Theaters usually post showtimes about a week ahead." : ""),
                        actionTitle: noNextFound ? nil
                            : searchingNext ? "Searching…"
                            : movie.isReleased && isFarFuture
                            ? "Find the closest \(filterLabel) date"
                            : "Find the next \(filterLabel) date",
                        action: findNextAction)
                        .disabled(searchingNext)
                    if noNextFound {
                        Text("Nothing matching in the next two weeks either — try loosening the filters.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    Spacer()
                }
            } else {
                theaterList
            }
        }
    }

    private var theaterList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredTheaters) { theater in
                    theaterCard(theater)
                }
                Text("Showtimes by Gracenote · $ = bargain pricing · tickets open in Fandango")
                    .font(.caption2)
                    .foregroundStyle(Theme.gray)
                    .padding(.vertical, 8)
            }
            .screenHPadding()
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    /// One theatre on an elevated card: name, seat perks, showtime chips.
    private func theaterCard(_ theater: TheaterShowtimes) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(theater.theaterName).font(.subheadline.weight(.bold)).lineLimit(2)
                if !theater.amenities.isEmpty {
                    // The closest thing showtime data has to seat info.
                    HStack(spacing: 4) {
                        Image(systemName: "sofa.fill").font(.system(size: 9))
                        Text(theater.amenities.joined(separator: " · ")).font(.caption)
                    }
                    .foregroundStyle(Theme.marquee)
                }
            }
            FlowingChips(showtimes: theater.showtimes)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rCard).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.rCard).strokeBorder(Theme.hairline))
    }

    /// The empty states' CTA — nil once the two-week probe came up dry.
    private var findNextAction: (() -> Void)? {
        noNextFound ? nil : { Task { await findNextAvailable() } }
    }

    /// Selected date is far enough out that theaters likely haven't posted
    /// schedules yet — worth saying, so an empty day doesn't read as "gone".
    private var isFarFuture: Bool {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                      to: cal.startOfDay(for: date)).day ?? 0
        return days > 7
    }

    /// No showings on this date — offer to jump to the nearest date that has any.
    private var noShowingsView: some View {
        VStack(spacing: 0) {
            Spacer()
            EmptyStateView(
                icon: "ticket",
                title: isFarFuture ? "No showings posted yet" : "No showings",
                message: "\(movie.title) isn't playing near \(zipcode) on this date."
                    + (isFarFuture ? " Theaters usually post showtimes about a week ahead." : ""),
                actionTitle: noNextFound ? nil
                    : searchingNext ? "Searching…"
                    : movie.isReleased && isFarFuture
                    ? "Find the closest date with showtimes"
                    : "Find the next date with showtimes",
                action: findNextAction)
                .disabled(searchingNext)
            if noNextFound {
                Text("Nothing in the next two weeks either — try another ZIP code.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Dates worth probing for showings, nearest-first. Normally the two
    /// weeks after the selected date — but for a film that's ALREADY OUT and
    /// a date picked from the calendar weeks ahead, its showings live near
    /// TODAY (theaters only post about a week out), so probe from today
    /// instead of marching further into the future.
    private var probeDates: [Date] {
        let today = cal.startOfDay(for: Date())
        let selected = cal.startOfDay(for: date)
        if selected > today {
            // A future date drew a blank: check today→selected first (a
            // running film's showings live near today; an unreleased one may
            // have PREVIEWS before its date), then march past the selection.
            let before = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
                .filter { $0 < selected }
            let after = (1...14).compactMap { cal.date(byAdding: .day, value: $0, to: selected) }
            return Array((before + after).prefix(14))
        }
        return (1...14).compactMap { cal.date(byAdding: .day, value: $0, to: selected) }
    }

    /// Probe day-by-day (up to two weeks) for the first date with a matching
    /// showing, then jump the picker there.
    private func findNextAvailable() async {
        guard zipcode.count == 5, !searchingNext else { return }
        searchGen += 1
        let gen = searchGen
        searchingNext = true
        defer { searchingNext = false }
        for probe in probeDates {
            do {
                // An empty result is "no showings that day" → keep probing; a
                // thrown error is a real failure (network/config) → stop, don't
                // hammer the API 14 times on an outage.
                let found = try await ShowtimesService.shared.showtimes(
                    for: movie, zipcode: zipcode, date: probe, radius: radius)
                // The user started a fresh search (chip tap, new radius)
                // mid-probe — theirs wins, this probe stands down.
                guard gen == searchGen else { return }
                // Honor the active filters: someone hunting IMAX recliners
                // wants the next date WITH such a showing, not just any.
                let matches = found.contains { matchesFilters($0) }
                if matches {
                    suppressSearch = true   // we already have this date's showtimes
                    date = probe
                    theaters = found
                    state = .loaded
                    return
                }
            } catch {
                guard gen == searchGen else { return }
                // A real failure (network/config) — say so, rather than
                // claiming there's nothing playing for two weeks.
                state = .error("Couldn't check upcoming dates — try again.")
                return
            }
        }
        guard gen == searchGen else { return }
        noNextFound = true
    }

    /// All zero/error states share the app-wide EmptyStateView look.
    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            EmptyStateView(icon: icon, title: title, message: message)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Tap the location glyph: permission → position → ZIP → search.
    private func fillFromLocation() async {
        isLocating = true
        defer { isLocating = false }
        do {
            let zip = try await LocationZip.shared.currentZip()
            zipInput = zip
            zipcode = zip
            await search()
        } catch {
            let message = (error as? LocationZip.LocationError) == .denied
                ? "Location is off for Cini — allow it in Settings, or type your ZIP code."
                : "Couldn't pin down your location — type your ZIP code instead."
            // Results already on screen survive a failed location tap — the
            // message rides a toast instead of replacing the whole list.
            if case .loaded = state {
                ToastCenter.shared.show(message)
            } else {
                state = .error(message)
            }
        }
    }

    private func search() async {
        guard zipcode.count == 5 else { return }
        searchGen += 1
        let gen = searchGen
        noNextFound = false
        state = .loading
        do {
            let found = try await ShowtimesService.shared.showtimes(
                for: movie, zipcode: zipcode, date: date, radius: radius)
            // Superseded while in flight (a newer chip/radius search
            // started)? Discard — only the latest may commit.
            guard gen == searchGen else { return }
            theaters = found
            state = .loaded
            // First successful load: open on the user's preferred screen if
            // it's actually playing (Settings → Viewing preferences).
            if !didAutoSelectFormat, !theaters.isEmpty {
                // Consumed only when there was something to consider — an
                // empty first load (a future date) must not burn the
                // preferred-screen pre-filter for the whole open.
                didAutoSelectFormat = true
                if screenFormat == nil,
                   let favorite = PrefsCache.shared.screenFormats
                       .first(where: { availableFormats.contains($0) }) {
                    screenFormat = favorite
                }
            }
            // The screen filter deliberately carries across dates — a date
            // with no such screenings shows the "No IMAX showings" state
            // with "find the next IMAX date", not a silent reset.
            // Remember the zip — it powers "your watchlist movie is
            // playing near you" push alerts. Best-effort here (the user came
            // for showtimes, which loaded), but leave a trace on failure.
            do { try await SupabaseService.shared.setHomeZip(zipcode) }
            catch { SupabaseService.logSwallowed("setHomeZip", error) }
        } catch ShowtimesError.notConfigured {
            guard gen == searchGen else { return }
            state = .notConfigured
        } catch ShowtimesError.zipcodeNotFound {
            guard gen == searchGen else { return }
            state = .error("We couldn't find that ZIP code.")
        } catch {
            guard gen == searchGen else { return }
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
                // Only a missing ticket link disables the chip. "Past" is
                // judged in DEVICE time while showtimes are theatre-local —
                // searching a zip in another timezone must not lock out a
                // perfectly bookable showing, so past ones just dim.
                .disabled(showtime.bookingURL == nil)
                // VoiceOver hears the real state, not "7:30 PM · dollar".
                .accessibilityLabel([
                    showtime.startTime.formatted(date: .omitted, time: .shortened),
                    showtime.format,
                    showtime.isBargain ? "bargain price" : nil,
                    isNext ? "next showing" : nil,
                    isPast ? "already started" : nil,
                    showtime.bookingURL == nil ? "no online tickets" : nil,
                ].compactMap { $0 }.joined(separator: ", "))
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
