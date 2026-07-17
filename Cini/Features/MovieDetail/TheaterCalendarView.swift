import SwiftUI

/// A theatrical calendar centered on your Want to Watch. Your saved movies —
/// the ones playing now and the ones coming — are shown prominently, and
/// general release dates are overlaid too but styled differently (a muted dot
/// and a plain "Releases …" line) so your own list stands out at a glance.
/// A filter narrows to just your list. List and Month views. Each title
/// offers Tickets (showtimes) and a bookmark; tapping opens the movie page.
struct TheaterCalendarView: View {
    enum Scope: String, CaseIterable { case all, mine }

    @State private var scope: Scope
    init(scope: Scope = .all) { _scope = State(initialValue: scope) }

    @Environment(RankingStore.self) private var store

    @State private var releases: [Movie] = []      // general upcoming (all)
    @State private var nowOut: [Movie] = []         // general, in theaters now
    @State private var myMovies: [Movie] = []       // Want to Watch, in theaters / coming
    @State private var releasesLoaded = false
    @State private var myLoaded = false

    /// Powers the Tickets/showtimes sheet — shared with ShowtimesSheet.
    @AppStorage("showtimes.zipcode") private var zipcode = ""
    @State private var showZipEntry = false
    @State private var zipDraft = ""

    @State private var mode: Mode = .month   // the calendar IS the feature — default to it
    @State private var visibleMonth = Date()
    @State private var selectedDay: Date?
    @State private var detailMovie: Movie?
    @State private var activeSheet: ActiveSheet?

    private enum Mode { case list, month }

    private enum ActiveSheet: Identifiable {
        case tickets(Movie), save(Movie)
        var id: String {
            switch self {
            case .tickets(let m): return "t\(m.tmdbID)"
            case .save(let m): return "s\(m.tmdbID)"
            }
        }
    }

    private let cal = Calendar.current
    private static let weekdaySymbols: [String] = {
        let f = DateFormatter()
        f.locale = .current
        return f.shortWeekdaySymbols ?? ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
    }()

    // MARK: - Data (my list, emphasized, overlaid with general releases)

    private var watchlistIDs: Set<Int> { Set(store.watchlist.map(\.movieID)) }
    private func isMine(_ movie: Movie) -> Bool { watchlistIDs.contains(movie.tmdbID) }

    /// Everything to show in "All" scope: general now-playing + upcoming
    /// releases, plus my saved titles — de-duped (my copy wins, it has the
    /// exact date). Including the general now-playing set keeps the calendar
    /// full even when nothing on your list is in theaters. "My list" scope
    /// shows only my titles.
    private var movies: [Movie] {
        if scope == .mine { return myMovies }
        var byID: [Int: Movie] = [:]
        for m in nowOut where m.tmdbID > 0 { byID[m.tmdbID] = m }
        for m in releases { byID[m.tmdbID] = m }
        for m in myMovies { byID[m.tmdbID] = m }
        return Array(byID.values)
    }
    /// Ready to show: the general feed for All, my titles for My list. (In All,
    /// the now-playing strip fills in when the watchlist set finishes loading.)
    private var scopeLoaded: Bool { scope == .mine ? myLoaded : releasesLoaded }

    private func releaseDate(_ movie: Movie) -> Date? {
        movie.releaseDateFull.flatMap { DateFormatter.localDay.date(from: $0) }
    }

    private var nowPlaying: [Movie] {
        movies.filter(\.isReleased)
            .sorted {
                // Your saved titles lead the now-playing strip.
                if isMine($0) != isMine($1) { return isMine($0) }
                return (releaseDate($0) ?? .distantPast) > (releaseDate($1) ?? .distantPast)
            }
    }
    private var coming: [Movie] {
        movies.filter { !$0.isReleased }
            .sorted {
                // My titles float above general releases on the same day.
                if isMine($0) != isMine($1) { return isMine($0) }
                return (releaseDate($0) ?? .distantFuture) < (releaseDate($1) ?? .distantFuture)
            }
    }
    private var datedComing: [Movie] { coming.filter { releaseDate($0) != nil } }
    private var undatedComing: [Movie] { coming.filter { releaseDate($0) == nil } }
    /// Month-grid contents for one day. Upcoming titles sit on their release
    /// day; everything IN THEATERS NOW sits on TODAY (a running film's opening
    /// day is often last month — plotting it there hid it from this month's
    /// page, which read as "my movies aren't on the grid").
    private var byDay: [Date: [Movie]] {
        var days = Dictionary(grouping: datedComing) { cal.startOfDay(for: releaseDate($0)!) }
        if !nowPlaying.isEmpty {
            let today = cal.startOfDay(for: Date())
            days[today, default: []].insert(contentsOf: nowPlaying, at: 0)
        }
        return days
    }
    private var isEmpty: Bool { nowPlaying.isEmpty && coming.isEmpty }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            controls
            Group {
                if !scopeLoaded {
                    Spacer(); ProgressView(); Spacer()
                } else if isEmpty {
                    emptyState
                } else if mode == .list {
                    listBody
                } else {
                    monthBody
                }
            }
        }
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("In Theaters")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tickets(let movie):
                ShowtimesSheet(movie: movie,
                               initialDate: movie.isReleased ? nil : releaseDate(movie))
            case .save(let movie):
                SaveToListSheet(movie: movie)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .navigationDestination(item: $detailMovie) { MovieDetailView(movie: $0) }
        .task {
            // Both load: general releases for the calendar, my saved set so
            // my titles are marked and my now-playing appears.
            async let a: () = loadReleases()
            async let b: () = loadMine()
            _ = await (a, b)
            resetMonth()
        }
        .onChange(of: scope) { _, _ in resetMonth() }
        .onChange(of: myLoaded) { _, _ in if selectedDay == nil { resetMonth() } }
    }

    // MARK: - Controls (mode toggle styled like Recs Find/Rank, + scope filter)

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: your area (for showtimes) on the left, the view toggle on
            // the right. The toggle is fixedSize so its labels never truncate.
            HStack {
                locationButton
                Spacer(minLength: 8)
                modeToggle.fixedSize()
            }
            // Row 2: scope filter on its own line so it never crowds the toggle.
            HStack(spacing: 8) {
                FilterPill(title: "All releases", hasChevron: false, active: scope == .all) {
                    Haptics.tap(); scope = .all
                }
                FilterPill(title: "On my list", hasChevron: false, active: scope == .mine) {
                    Haptics.tap(); scope = .mine
                }
                Spacer()
                // The dot legend explains the MONTH grid only (List rows use
                // text badges), and only in All scope where both kinds appear.
                if scope == .all, mode == .month {
                    legendDot(Theme.marquee, "Yours")
                    legendDot(Theme.gray.opacity(0.55), "Releasing")
                }
            }
        }
        .screenHPadding()
        .padding(.top, 8)
        .padding(.bottom, 10)
        .alert("Your area", isPresented: $showZipEntry) {
            TextField("ZIP code", text: $zipDraft).keyboardType(.numberPad)
            Button("Save") {
                let z = zipDraft.filter(\.isNumber)
                guard z.count == 5 else { return }
                zipcode = z
                Task { try? await SupabaseService.shared.setHomeZip(z) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used to show showtimes near you when you tap Tickets.")
        }
    }

    /// Compact location chip → prompts for a ZIP that feeds the Tickets sheet.
    private var locationButton: some View {
        Button {
            zipDraft = zipcode; showZipEntry = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mappin.and.ellipse").font(.caption.weight(.bold))
                Text(zipcode.isEmpty ? "Set your area" : zipcode)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.marquee)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(zipcode.isEmpty ? "Set your area for showtimes"
                                            : "Your area, ZIP \(zipcode)")
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(Theme.gray)
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeSegment(.list, icon: "list.bullet", label: "List")
            modeSegment(.month, icon: "calendar", label: "Month")
        }
        .padding(3)
        .background(Capsule().fill(Theme.fill))
    }

    private func modeSegment(_ option: Mode, icon: String, label: String) -> some View {
        let on = mode == option
        return Button {
            withAnimation(.snappy) { mode = option }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(label).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(on ? Theme.background : Theme.gray)
            .padding(.horizontal, 11).frame(height: 30)
            .background(Capsule().fill(on ? Theme.marquee : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) view\(on ? ", selected" : "")")
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "calendar",
            title: scope == .mine ? "Nothing on your list in theaters" : "No upcoming releases",
            message: scope == .mine
                ? "Save movies to Want to Watch and the ones playing (or coming) to theaters show up here."
                : "Check back soon — new movies land here as they're announced.")
    }

    // MARK: - List mode

    private var listBody: some View {
        List {
            if !nowPlaying.isEmpty {
                Section("In theaters now") { ForEach(nowPlaying) { movieRow($0) } }
            }
            if !datedComing.isEmpty {
                Section("Coming soon") { ForEach(datedComing) { movieRow($0) } }
            }
            if !undatedComing.isEmpty {
                Section("Date to be announced") { ForEach(undatedComing) { movieRow($0) } }
            }
        }
        .listStyle(.plain)
    }

    private func movieRow(_ movie: Movie) -> some View {
        let mine = isMine(movie)
        return HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(movie.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if mine {
                        Text("On your list")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.marquee)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.marquee.opacity(0.15)))
                    }
                }
                Text(dateLine(movie))
                    .font(.caption.weight(.semibold))
                    // Your titles read in the accent colors; general releases
                    // are a quieter gray so they don't compete with yours.
                    .foregroundStyle(mine ? (movie.isReleased ? Theme.scoreGreen : Theme.marquee) : Theme.gray)
                if !movie.genres.isEmpty {
                    Text(movie.genres.prefix(2).joined(separator: ", "))
                        .font(.caption).foregroundStyle(Theme.gray)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                if movie.tmdbID > 0 {
                    PillButton(title: "Tickets", systemImage: "ticket", style: .outlined) {
                        activeSheet = .tickets(movie)
                    }
                }
                Button {
                    bookmarkTapped(movie: movie, store: store) { activeSheet = .save(movie) }
                } label: {
                    Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isOnWatchlist(movie.tmdbID)
                    ? "Remove from Want to Watch" : "Bookmark to Want to Watch")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { detailMovie = movie }
        .listRowBackground(Theme.background)
    }

    private func dateLine(_ movie: Movie) -> String {
        if movie.isReleased { return "In theaters now" }
        if let date = releaseDate(movie) {
            let day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            return isMine(movie) ? day : "Releases \(day)"
        }
        return "Coming soon"
    }

    // MARK: - Month mode

    private var monthBounds: (lower: Date, upper: Date) {
        let lower = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let lastDate = datedComing.compactMap(releaseDate).max() ?? lower
        let upper = cal.date(from: cal.dateComponents([.year, .month], from: lastDate))!
        return (lower, max(lower, upper))
    }

    private var monthBody: some View {
        ScrollView {
            VStack(spacing: 16) {
                monthGrid
                if let day = selectedDay, let films = byDay[day], !films.isEmpty {
                    posterStrip(title: cal.isDateInToday(day)
                                    ? "Today — in theaters now"
                                    : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                                films)
                } else if byDay.isEmpty {
                    Text("No dated releases yet — check the List view.")
                        .font(.caption).foregroundStyle(Theme.gray).padding(.top, 4)
                } else {
                    Text("Tap a highlighted day to see what opens.")
                        .font(.caption).foregroundStyle(Theme.gray).padding(.top, 4)
                }
                if !undatedComing.isEmpty { posterStrip(title: "Date to be announced", undatedComing) }
            }
            .padding(.vertical, 8)
        }
    }

    private var monthGrid: some View {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: visibleMonth))!
        let daysInMonth = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let firstWeekday = cal.component(.weekday, from: start)
        let leadingBlanks = (firstWeekday - cal.firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
            + (0..<daysInMonth).map { cal.date(byAdding: .day, value: $0, to: start) }
        let bounds = monthBounds
        let weekdays = Self.weekdaySymbols.rotated(by: cal.firstWeekday - 1)

        return VStack(spacing: 10) {
            HStack {
                monthArrow("chevron.left", enabled: start > bounds.lower) { step(-1) }
                Spacer()
                Text(start.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                monthArrow("chevron.right", enabled: start < bounds.upper) { step(1) }
            }
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(.caption2.weight(.semibold)).foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in dayCell(day) }
            }
        }
        .screenHPadding()
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let key = cal.startOfDay(for: day)
            let films = byDay[key] ?? []
            let mineHere = films.contains(where: isMine)
            let count = films.count
            let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
            let isToday = cal.isDateInToday(day)
            // Gold = a title from your list opens; muted = general release only.
            let dotColor: Color = mineHere ? Theme.marquee
                : (count > 0 ? Theme.gray.opacity(0.55) : .clear)
            Button {
                if count > 0 { Haptics.tap(); selectedDay = key }
            } label: {
                VStack(spacing: 3) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.footnote.weight(mineHere ? .bold : (count > 0 ? .semibold : .regular)))
                        .foregroundStyle(count > 0 ? Theme.ink : Theme.gray.opacity(0.6))
                    Circle().fill(dotColor).frame(width: 5, height: 5)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Theme.marquee.opacity(0.16) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isToday ? Theme.marquee.opacity(0.5) : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            // Always name the date (an empty label would hide it from VoiceOver);
            // add the release count when there is one.
            .accessibilityLabel(count > 0
                ? "\(day.formatted(.dateTime.month().day())), \(count) release\(count == 1 ? "" : "s")\(mineHere ? ", on your list" : "")"
                : day.formatted(.dateTime.month().day()))
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private func monthArrow(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(enabled ? Theme.marquee : Theme.gray.opacity(0.35))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func step(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        Haptics.tap()
        withAnimation(.snappy) {
            visibleMonth = next
            selectedDay = firstReleaseDay(in: next)
        }
    }

    /// Compact poster card. My titles get a gold ring; general releases don't.
    private func posterStrip(title: String, _ films: [Movie]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold)).tracking(0.5)
                .foregroundStyle(Theme.gray).screenHPadding()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(films) { movie in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterView(url: movie.posterURL, width: 104)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(isMine(movie) ? Theme.marquee : .clear, lineWidth: 2))
                                .onTapGesture { detailMovie = movie }
                            Text(movie.title)
                                .font(.caption.weight(.semibold)).lineLimit(2)
                                .frame(width: 104, alignment: .leading)
                            if movie.tmdbID > 0 {
                                // Card-width compact ticket button — PillButton's
                                // padding overflowed 104pt and truncated to "Tick…".
                                Button { activeSheet = .tickets(movie) } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "ticket").font(.caption2)
                                        Text("Tickets").font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(Theme.marquee)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(Capsule().strokeBorder(Theme.marquee.opacity(0.5), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .frame(width: 104)
                            }
                        }
                        .frame(width: 104)
                    }
                }
                .screenHPadding()
            }
        }
    }

    // MARK: - Loading

    private func firstReleaseDay(in month: Date) -> Date? {
        let comps = cal.dateComponents([.year, .month], from: month)
        return byDay.keys.filter { cal.dateComponents([.year, .month], from: $0) == comps }.min()
    }

    private func resetMonth() {
        let today = cal.startOfDay(for: Date())
        if !nowPlaying.isEmpty {
            // Today carries everything in theaters now — land there, selected.
            visibleMonth = today
            selectedDay = today
        } else if let soonest = datedComing.compactMap(releaseDate).min() {
            visibleMonth = soonest
            selectedDay = firstReleaseDay(in: soonest)
        }
    }

    private func loadReleases() async {
        guard !releasesLoaded else { return }
        async let upcoming = TMDBService.shared.upcoming()
        async let playing = TMDBService.shared.nowOut()
        releases = (try? await upcoming) ?? []
        nowOut = ((try? await playing) ?? []).filter { $0.tmdbID > 0 }
        releasesLoaded = true
    }

    private func loadMine() async {
        guard !myLoaded else { return }
        myMovies = await watchlistInTheaters()
        myLoaded = true
    }

    /// Want to Watch movies that are theater-relevant: released within the last
    /// ~4 months (still in theaters) or still upcoming. Only fetch exact dates
    /// for titles from roughly the current era.
    private func watchlistInTheaters() async -> [Movie] {
        let year = Calendar(identifier: .gregorian).component(.year, from: .now)
        let candidates = store.watchlist
            .compactMap { store.movie($0.movieID) }
            .filter { $0.tmdbID > 0 }
            .filter { ($0.releaseYear ?? year) >= year - 1 }
            .sorted { ($0.releaseYear ?? 0) > ($1.releaseYear ?? 0) }
            .prefix(60)

        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        var result: [Movie] = []
        await withTaskGroup(of: Movie?.self) { group in
            for movie in candidates {
                group.addTask { (try? await TMDBService.shared.details(for: movie.tmdbID)) ?? movie }
            }
            for await movie in group {
                guard let movie else { continue }
                let date = movie.releaseDateFull.flatMap { DateFormatter.localDay.date(from: $0) }
                if !movie.isReleased || (date.map { $0 >= cutoff } ?? true) {
                    result.append(movie)
                }
            }
        }
        return result
    }
}

private extension Array {
    /// Left-rotate by `n` (for aligning weekday symbols to `firstWeekday`).
    func rotated(by n: Int) -> [Element] {
        guard !isEmpty else { return self }
        let k = ((n % count) + count) % count
        return Array(self[k...] + self[..<k])
    }
}
