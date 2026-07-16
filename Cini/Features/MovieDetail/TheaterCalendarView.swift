import SwiftUI

/// One theatrical browser with a List and a Month view, and a scope filter:
///   • All releases — everything coming to theaters.
///   • My list — the movies on your Want to Watch, so you can see what's
///     playing now and what's coming, and when.
/// The two entry points (the feed's calendar, and Want to Watch's "In
/// theaters") just open it on a different default scope. Each title offers
/// Tickets (showtimes) and a bookmark; tapping opens the movie page.
struct TheaterCalendarView: View {
    enum Scope: String, CaseIterable { case all, mine }
    var scope: Scope = .all

    @Environment(RankingStore.self) private var store

    // Both datasets are cached so flipping the filter is instant; the
    // watchlist set is fetched lazily the first time it's needed.
    @State private var allMovies: [Movie] = []
    @State private var listMovies: [Movie] = []
    @State private var allLoaded = false
    @State private var listLoaded = false
    @State private var listLoading = false

    @State private var mode: Mode = .list
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

    // MARK: - Scope-selected data

    private var movies: [Movie] { scope == .all ? allMovies : listMovies }
    private var scopeLoaded: Bool { scope == .all ? allLoaded : listLoaded }

    private func releaseDate(_ movie: Movie) -> Date? {
        movie.releaseDateFull.flatMap { DateFormatter.localDay.date(from: $0) }
    }

    /// Out now (only the "my list" scope has these — all releases is future).
    private var nowPlaying: [Movie] {
        movies.filter(\.isReleased)
            .sorted { (releaseDate($0) ?? .distantPast) > (releaseDate($1) ?? .distantPast) }
    }
    private var coming: [Movie] {
        movies.filter { !$0.isReleased }
            .sorted { (releaseDate($0) ?? .distantFuture) < (releaseDate($1) ?? .distantFuture) }
    }
    private var datedComing: [Movie] { coming.filter { releaseDate($0) != nil } }
    private var undatedComing: [Movie] { coming.filter { releaseDate($0) == nil } }

    private var byDay: [Date: [Movie]] {
        Dictionary(grouping: datedComing) { cal.startOfDay(for: releaseDate($0)!) }
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
            if !allLoaded {
                allMovies = (try? await TMDBService.shared.upcoming()) ?? []
                allLoaded = true
            }
            if scope == .mine { await loadListIfNeeded() }
            resetMonth()
        }
        .onChange(of: scope) { _, _ in
            Task { await loadListIfNeeded(); resetMonth() }
        }
    }

    // MARK: - Controls (mode toggle + scope filter, styled like Recs)

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                modeToggle
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterPill(title: "All releases", hasChevron: false, active: scope == .all) {
                        Haptics.tap(); scope = .all
                    }
                    FilterPill(title: "On my list", hasChevron: false, active: scope == .mine) {
                        Haptics.tap(); scope = .mine
                    }
                }
            }
        }
        .screenHPadding()
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Labeled icon+label pill toggle — the same shape as the Recs Find/Rank
    /// toggle, so the two read as the same kind of control.
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
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(on ? Theme.marquee : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) view\(on ? ", selected" : "")")
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "calendar",
            title: scope == .all ? "No upcoming releases" : "Nothing to catch in theaters",
            message: scope == .all
                ? "Check back soon — new movies land here as they're announced."
                : "Save movies to Want to Watch and the ones playing (or coming) to theaters show up here.")
    }

    // MARK: - List mode

    private var listBody: some View {
        List {
            if !nowPlaying.isEmpty {
                Section("In theaters now") { ForEach(nowPlaying) { movieRow($0) } }
            }
            if !datedComing.isEmpty {
                Section(scope == .all ? "" : "Coming soon") { ForEach(datedComing) { movieRow($0) } }
            }
            if !undatedComing.isEmpty {
                Section("Date to be announced") { ForEach(undatedComing) { movieRow($0) } }
            }
        }
        .listStyle(.plain)
    }

    private func movieRow(_ movie: Movie) -> some View {
        HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(dateLine(movie))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(movie.isReleased ? Theme.scoreGreen : Theme.marquee)
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
                if !nowPlaying.isEmpty { posterStrip(title: "In theaters now", nowPlaying) }
                monthGrid
                if let day = selectedDay, let films = byDay[day], !films.isEmpty {
                    posterStrip(title: day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                                films)
                } else if datedComing.isEmpty {
                    Text("No dated releases yet — check the List view.")
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
            let count = byDay[key]?.count ?? 0
            let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
            let isToday = cal.isDateInToday(day)
            Button {
                if count > 0 { Haptics.tap(); selectedDay = key }
            } label: {
                VStack(spacing: 3) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.footnote.weight(count > 0 ? .bold : .regular))
                        .foregroundStyle(count > 0 ? Theme.ink : Theme.gray.opacity(0.6))
                    Circle().fill(count > 0 ? Theme.marquee : .clear).frame(width: 5, height: 5)
                }
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Theme.marquee.opacity(0.16) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isToday ? Theme.marquee.opacity(0.5) : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .accessibilityLabel(count > 0
                ? "\(day.formatted(.dateTime.month().day())), \(count) release\(count == 1 ? "" : "s")"
                : "")
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private func monthArrow(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(enabled ? Theme.marquee : Theme.gray.opacity(0.35))
                .frame(width: 40, height: 34).contentShape(Rectangle())
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
                                .onTapGesture { detailMovie = movie }
                            Text(movie.title)
                                .font(.caption.weight(.semibold)).lineLimit(2)
                                .frame(width: 104, alignment: .leading)
                            if movie.tmdbID > 0 {
                                PillButton(title: "Tickets", systemImage: "ticket", style: .outlined) {
                                    activeSheet = .tickets(movie)
                                }
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
        if let soonest = datedComing.compactMap(releaseDate).min() {
            visibleMonth = soonest
            selectedDay = firstReleaseDay(in: soonest)
        }
    }

    private func loadListIfNeeded() async {
        guard scope == .mine, !listLoaded, !listLoading else { return }
        listLoading = true
        listMovies = await watchlistInTheaters()
        listLoaded = true
        listLoading = false
    }

    /// Want to Watch movies that are theater-relevant: released within the last
    /// ~4 months (still in theaters) or still upcoming. Only fetch exact dates
    /// for titles from roughly the current era — catalog classics aren't in
    /// theaters, so there's no point paying for their details.
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
                group.addTask {
                    (try? await TMDBService.shared.details(for: movie.tmdbID)) ?? movie
                }
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
