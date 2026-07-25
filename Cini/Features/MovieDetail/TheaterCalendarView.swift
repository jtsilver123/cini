import SwiftUI

/// A theatrical calendar centered on your Want to Watch. Your saved movies —
/// the ones playing now and the ones coming — are shown prominently, and
/// general release dates are overlaid too but styled differently (a muted dot
/// and a plain "Releases …" line) so your own list stands out at a glance.
/// A filter narrows to just your list. List and Month views. Each title
/// offers Tickets (showtimes) and a bookmark; tapping opens the movie page.
struct TheaterCalendarView: View {
    enum Scope: String, CaseIterable { case all, mine }

    // Your list is the default lens (like Month is the default view) —
    // "All releases" stays one tap away.
    @State private var scope: Scope
    init(scope: Scope = .mine) { _scope = State(initialValue: scope) }

    @Environment(RankingStore.self) private var store

    @State private var releases: [Movie] = []      // general upcoming (all)
    @State private var nowOut: [Movie] = []         // general, in theaters now
    @State private var myMovies: [Movie] = []       // Want to Watch, in theaters / coming
    @State private var releasesLoaded = false
    @State private var myLoaded = false

    /// Powers the Tickets/showtimes sheet — shared with ShowtimesSheet.
    @AppStorage("showtimes.zipcode") private var zipcode = ""
    @AppStorage("showtimes.radius") private var radius = 15
    /// The user's muted-kinds set, refreshed every time the area sheet
    /// opens. The toggle itself flips ONLY 'watchlist_showing', via an
    /// atomic server-side RPC — never a whole-array write that could
    /// clobber mutes changed in Settings or on another device.
    @State private var mutedKinds: Set<String> = []
    @State private var alertPrefLoaded = false
    @State private var showZipEntry = false
    @State private var zipDraft = ""
    /// List-view search query (title match).
    @State private var listSearch = ""
    /// tmdbID → days it VERIFIABLY plays near the user's zip (Gracenote,
    /// next-week window). Drives the grid's future-day marks.
    @State private var localDays: [Int: Set<Date>] = [:]
    /// The zip the current `localDays` answers for — refetch when it changes.
    @State private var checkedZip = ""
    /// 14-day schedule windows already fetched (0 = today, 1 = +14d, …) —
    /// paging into the future fetches its window in real time, so days
    /// beyond the first fortnight fill in as theaters post them.
    @State private var fetchedWindows: Set<Int> = []
    /// Films playing nearby that no loaded set (charts, upcoming, your list)
    /// included — resolved from the local schedule so "All releases" is
    /// exhaustive for what's actually showing.
    @State private var localFilms: [Movie] = []
    /// Months ("yyyy-m") whose releases were already fetched — each month
    /// fills on first arrival, so you can page as far ahead as you like.
    @State private var fetchedMonths: Set<String> = []
    /// Months currently fetching — keyed like fetchedMonths, so fast paging
    /// can't flash a false "nothing announced" for a month still loading.
    @State private var loadingMonths: Set<String> = []
    private var monthLoading: Bool {
        let comps = cal.dateComponents([.year, .month], from: visibleMonth)
        return loadingMonths.contains("\(comps.year ?? 0)-\(comps.month ?? 0)")
    }

    @State private var mode: Mode = .month   // the calendar IS the feature — default to it
    @State private var visibleMonth = Date()
    @State private var selectedDay: Date?
    @State private var detailMovie: Movie?
    @State private var activeSheet: ActiveSheet?
    /// Rank flow launched from a poster card's (+) quick action.
    @State private var logMovie: Movie?

    private enum Mode { case list, month }

    private enum ActiveSheet: Identifiable {
        /// Tickets carries the day the user was looking at, so the showtimes
        /// sheet opens on THAT date (tapping Tickets on Aug 13 asks about
        /// Aug 13, not today).
        case tickets(Movie, Date?), save(Movie)
        var id: String {
            switch self {
            case .tickets(let m, _): return "t\(m.tmdbID)"
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

    private var watchlistIDs: Set<Int> { store.watchlistIDs }
    private func isMine(_ movie: Movie) -> Bool { watchlistIDs.contains(movie.tmdbID) }

    /// Everything to show in "All" scope: general now-playing + upcoming
    /// releases, plus my saved titles — de-duped (my copy wins, it has the
    /// exact date). Including the general now-playing set keeps the calendar
    /// full even when nothing on your list is in theaters. "My list" scope
    /// shows only my titles.
    private var movies: [Movie] {
        if scope == .mine {
            // Live-filtered against the CURRENT watchlist: un-bookmarking
            // drops a title instantly, and a film bookmarked moments ago in
            // the All view joins without a refetch.
            var byID: [Int: Movie] = [:]
            for m in localFilms where isMine(m) { byID[m.tmdbID] = m }
            for m in nowOut where isMine(m) { byID[m.tmdbID] = m }
            for m in releases where isMine(m) { byID[m.tmdbID] = m }
            for m in myMovies where isMine(m) { byID[m.tmdbID] = m }
            return Array(byID.values)
        }
        var byID: [Int: Movie] = [:]
        for m in localFilms where m.tmdbID > 0 { byID[m.tmdbID] = m }
        for m in nowOut where m.tmdbID > 0 { byID[m.tmdbID] = m }
        for m in releases { byID[m.tmdbID] = m }
        for m in myMovies { byID[m.tmdbID] = m }
        return Array(byID.values)
    }
    /// Ready to show: the general feed for All, my titles for My list. (In All,
    /// the now-playing strip fills in when the watchlist set finishes loading.)
    private var scopeLoaded: Bool { scope == .mine ? myLoaded : releasesLoaded }

    /// Parsed release dates, memoized by their string — `releaseDate` is
    /// called inside the nowPlaying/coming/datedComing sort comparators, which
    /// re-run every render, so re-parsing the same string with a DateFormatter
    /// each time (n·log n per render) was measurable jank on a full calendar.
    private static var releaseDateCache: [String: Date] = [:]

    private func releaseDate(_ movie: Movie) -> Date? {
        guard let s = movie.releaseDateFull else { return nil }
        if let cached = Self.releaseDateCache[s] { return cached }
        guard let d = DateFormatter.localDay.date(from: s) else { return nil }
        Self.releaseDateCache[s] = d
        return d
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
    /// day (a factual date). A film IN THEATERS NOW sits on TODAY — and on
    /// exactly the FUTURE days where it verifiably has a showing near the
    /// user's zip (`localDays`, one Gracenote lookup covering the week
    /// theaters have posted). The grid never claims a day the showtimes
    /// sheet can't back up.
    /// Per-day order: your openings, your running films, then general ones —
    /// the visible thumbnail is always yours when anything of yours plays.
    /// Verified local data is in hand for the current zip — day marks can be
    /// exact instead of assumed.
    private var hasLocalData: Bool {
        zipcode.count == 5 && checkedZip == zipcode
    }

    private var byDay: [Date: [Movie]] {
        var days: [Date: [Movie]] = [:]
        let today = cal.startOfDay(for: Date())
        for movie in nowPlaying {
            var markDays: Set<Date>
            if hasLocalData {
                // Exact: only the days it verifiably plays near you. A chart
                // film with no local showings doesn't sit on the grid at all.
                markDays = Set((localDays[movie.tmdbID] ?? []).filter { $0 >= today })
                guard !markDays.isEmpty else { continue }
            } else {
                // No zip / no data — the honest fallback is "in theaters now".
                markDays = [today]
            }
            for day in markDays { days[day, default: []].append(movie) }
        }
        for movie in datedComing {
            // Opening day (the factual date) — PLUS any verified showing
            // BEFORE it: advance screenings and previews are posted days the
            // showtimes sheet already shows, so the grid must mark them too.
            var markDays: Set<Date> = [cal.startOfDay(for: releaseDate(movie)!)]
            if let verified = localDays[movie.tmdbID] {
                markDays.formUnion(verified.filter { $0 >= today })
            }
            for day in markDays { days[day, default: []].append(movie) }
        }
        // No official date at all but verified local showings (festival runs,
        // one-off events): mark exactly the posted days.
        for movie in undatedComing {
            guard let verified = localDays[movie.tmdbID] else { continue }
            for day in verified where day >= today {
                days[day, default: []].append(movie)
            }
        }
        // In this dictionary an unreleased film only ever sits on its opening
        // day, so !isReleased ⇔ "opens that day".
        return days.mapValues { films in
            films.filter { isMine($0) && !$0.isReleased }
                + films.filter { isMine($0) && $0.isReleased }
                + films.filter { !isMine($0) && !$0.isReleased }
                + films.filter { !isMine($0) && $0.isReleased }
        }
    }
    private var isEmpty: Bool { nowPlaying.isEmpty && coming.isEmpty }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            controls
            Group {
                if !scopeLoaded {
                    // Skeleton, not a blank spinner — the shape of what's coming.
                    ScrollView {
                        ListSkeleton(rows: 7)
                            .screenHPadding()
                            .padding(.top, 8)
                    }
                    .scrollDisabled(true)
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
            case .tickets(let movie, let day):
                ShowtimesSheet(movie: movie, initialDate: day)
            case .save(let movie):
                SaveToListSheet(movie: movie)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .navigationDestination(item: $detailMovie) { MovieDetailView(movie: $0) }
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
        .task {
            // Both load: general releases for the calendar, my saved set so
            // my titles are marked and my now-playing appears.
            // ALL THREE in flight together: general releases, my saved set,
            // and the local schedule (its resolution step waits for the
            // pools internally) — serially this doubled the cold-open time.
            async let a: () = loadReleases()
            async let b: () = loadMine()
            async let c: () = ensureLocalCoverage(for: visibleMonth)
            _ = await (a, b)
            // The watchlist fetch can take seconds — never yank away a
            // month/day the user already picked while waiting.
            if selectedDay == nil { resetMonth() }
            await c
        }
        .onChange(of: scope) { _, _ in
            // Keep the user's place when the new scope still has something
            // on the selected day; only re-home when it doesn't.
            if let day = selectedDay, byDay[day]?.isEmpty == false { return }
            selectedDay = firstReleaseDay(in: visibleMonth)
            if selectedDay == nil { resetMonth() }
        }
        .onChange(of: myLoaded) { _, _ in if selectedDay == nil { resetMonth() } }
        .onChange(of: zipcode) { _, _ in resetLocalData() }
        .onChange(of: radius) { _, _ in resetLocalData() }
        .onChange(of: visibleMonth) { _, month in
            Task {
                // Both fetches in flight together; then, if the user is
                // still on this month with nothing selected, land on its
                // first marked day.
                async let a: () = loadMonth(month)
                async let b: () = ensureLocalCoverage(for: month)
                _ = await (a, b)
                if cal.isDate(visibleMonth, equalTo: month, toGranularity: .month),
                   selectedDay == nil {
                    selectedDay = firstReleaseDay(in: month)
                }
            }
        }
    }

    // MARK: - Controls (mode toggle styled like Recs Find/Rank, + scope filter)

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: your area (for showtimes) on the left, the view toggle on
            // the right. The toggle is fixedSize so its labels never truncate.
            HStack {
                locationButton
                alertBell
                Spacer(minLength: 8)
                modeToggle.fixedSize()
            }
            // Row 2: scope filter on its own line so it never crowds the
            // toggle. The default (On my list) leads, like Month does.
            HStack(spacing: 8) {
                FilterPill(title: "Want to Watch", hasChevron: false, active: scope == .mine) {
                    Haptics.tap(); scope = .mine
                }
                FilterPill(title: "All releases", hasChevron: false, active: scope == .all) {
                    Haptics.tap(); scope = .all
                }
                Spacer()
            }
            // Row 3: the legend explains the MONTH grid (List rows use text
            // badges). Shown in BOTH scopes, on its own line — sharing the
            // pill row overflowed and truncated the pills on small phones.
            if mode == .month {
                HStack(spacing: 10) {
                    Spacer()
                    legendSwatch(mine: true, "Yours")
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.marquee)
                        Text("Opens").font(.caption2).foregroundStyle(Theme.gray)
                    }
                    legendSwatch(mine: false, "Showing")
                }
            }
        }
        .screenHPadding()
        .padding(.top, 8)
        .padding(.bottom, 10)
        .sheet(isPresented: $showZipEntry) {
            areaSheet
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.visible)
        }
    }

    /// ZIP + search radius in one place — the radius drives both the
    /// calendar's verified marks and the showtimes sheet's default.
    private var areaSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Showtimes and the calendar use this to find theaters near you.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.marquee)
                    TextField("ZIP code", text: $zipDraft)
                        .keyboardType(.numberPad)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.rControl).fill(Theme.fill))
                HStack {
                    Text("Search radius").font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        ForEach([5, 10, 15, 25, 50], id: \.self) { miles in
                            Button {
                                radius = miles
                                // Keep the server's alert radius in step even
                                // if the user never taps Save.
                                if zipcode.count == 5 {
                                    let z = zipcode
                                    Task { try? await SupabaseService.shared.setHomeArea(zip: z, radius: miles) }
                                }
                            } label: {
                                if radius == miles {
                                    Label("\(miles) miles", systemImage: "checkmark")
                                } else {
                                    Text("\(miles) miles")
                                }
                            }
                        }
                    } label: {
                        FilterPill(title: "\(radius) mi", active: true)
                    }
                }
                Divider()
                // Theater-only notification setting: ticket on-sale alerts.
                // Just this one kind — the full notification menu lives in
                // Settings; here it's strictly "theater stuff".
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ticketAlertsOn ? "bell.badge.fill" : "bell.slash")
                        .foregroundStyle(ticketAlertsOn ? Theme.marquee : Theme.gray)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ticket alerts").font(.subheadline.weight(.semibold))
                        Text("One alert when tickets go on sale near you for a movie you've saved — IMAX pre-sales included.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: ticketAlertsBinding)
                        .labelsHidden()
                        .disabled(!alertPrefLoaded)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Ticket alerts, \(ticketAlertsOn ? "on" : "off")")
                PillButton(title: "Save") {
                    let z = zipDraft.filter(\.isNumber)
                    guard z.count == 5 else { return }
                    zipcode = z
                    // ZIP + radius together — the server's alert sweep honors
                    // the radius the user picked here.
                    let r = radius
                    Task { try? await SupabaseService.shared.setHomeArea(zip: z, radius: r) }
                    showZipEntry = false
                }
                .frame(maxWidth: .infinity)
                .disabled(zipDraft.filter(\.isNumber).count != 5)
                Spacer()
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("Your area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showZipEntry = false }
                }
            }
            .task { await loadAlertPref() }
        }
    }

    /// Default is ON (nothing muted server-side) — ticket alerts fire at
    /// most once per movie ever and only near the saved zip, so they're
    /// high-signal. A failed load keeps the toggle disabled rather than
    /// showing a state that might be wrong.
    private var ticketAlertsOn: Bool { !mutedKinds.contains("watchlist_showing") }

    private var ticketAlertsBinding: Binding<Bool> {
        Binding(
            get: { ticketAlertsOn },
            set: { enabled in
                Haptics.tap()
                let previous = mutedKinds
                if enabled { mutedKinds.remove("watchlist_showing") }
                else { mutedKinds.insert("watchlist_showing") }
                Task {
                    do {
                        // Atomic single-kind flip: rapid re-flips are
                        // last-write-wins for THIS kind only, and mutes set
                        // elsewhere are untouched.
                        try await SupabaseService.shared.setNotificationKindMuted(
                            "watchlist_showing", muted: !enabled)
                        if enabled {
                            // The toggle promises a push — if permission is
                            // denied, SAY so instead of silently never firing.
                            let granted = await PushManager.request()
                            if !granted {
                                ToastCenter.shared.show("Notifications are off for Cini — turn them on in Settings to get ticket alerts. You'll still see them in Notifications in the app.")
                            }
                        }
                    } catch {
                        mutedKinds = previous   // roll the switch back
                        ToastCenter.shared.saveFailed()
                    }
                }
            })
    }

    /// Refetches every call — the sheet must show the CURRENT server state,
    /// not a snapshot from the first time the view ever loaded.
    private func loadAlertPref() async {
        if let kinds = try? await SupabaseService.shared.mutedNotificationKinds() {
            mutedKinds = kinds
            alertPrefLoaded = true
        }
    }

    /// Compact bell chip beside the area control — the at-a-glance state of
    /// theater ticket alerts; tapping opens the same area sheet to change it.
    private var alertBell: some View {
        Button {
            zipDraft = zipcode
            showZipEntry = true
        } label: {
            // Neutral until the pref actually loads — claiming "on" while
            // the server might say muted would lie to the user.
            Image(systemName: !alertPrefLoaded ? "bell"
                  : ticketAlertsOn ? "bell.badge" : "bell.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(!alertPrefLoaded ? Theme.gray
                                 : ticketAlertsOn ? Theme.marquee : Theme.gray)
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(!alertPrefLoaded ? "Ticket alerts — open area settings"
                            : ticketAlertsOn ? "Ticket alerts on — open area settings"
                                             : "Ticket alerts off — open area settings")
        .task { await loadAlertPref() }
    }

    /// Compact location chip → prompts for a ZIP that feeds the Tickets sheet.
    private var locationButton: some View {
        Button {
            zipDraft = zipcode; showZipEntry = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "mappin.and.ellipse").font(.caption.weight(.bold))
                Text(zipcode.isEmpty ? "Set your area" : "\(zipcode) · \(radius) mi")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(Theme.marquee)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(zipcode.isEmpty ? "Set your area for showtimes"
                                            : "Your area, ZIP \(zipcode)")
    }

    /// Mini poster swatch matching exactly how days are marked on the grid:
    /// yours = bright with a gold ring, general = dimmed behind a hairline.
    private func legendSwatch(mine: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                // Solid gold for "yours" — the soft 16% tint all but vanished
                // on the cream light-mode background.
                .fill(mine ? Theme.marquee : Theme.gray.opacity(0.35))
                .frame(width: 8, height: 11)
            Text(label).font(.caption2).foregroundStyle(Theme.gray)
        }
    }

    private var modeToggle: some View {
        // The default (Month) leads, like On my list does in the scope row.
        HStack(spacing: 2) {
            modeSegment(.month, icon: "calendar", label: "Month")
            modeSegment(.list, icon: "list.bullet", label: "List")
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
            // onMarquee, not background: cream `background` washes out on
            // gold in light mode (Theme.swift documents exactly this).
            .foregroundStyle(on ? Theme.onMarquee : Theme.gray)
            .padding(.horizontal, 11).frame(height: 30)
            .background(Capsule().fill(on ? Theme.marquee : .clear))
            // Expand the hit area toward 44pt without growing the pill.
            .contentShape(Rectangle().inset(by: -7))
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

    /// Case-insensitive title match for the List view's search field.
    private func matchesSearch(_ movie: Movie) -> Bool {
        let query = listSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || movie.title.lowercased().contains(query)
    }

    private var listBody: some View {
        let playing = nowPlaying.filter(matchesSearch)
        let dated = datedComing.filter(matchesSearch)
        let undated = undatedComing.filter(matchesSearch)
        return List {
            // Find one film fast in a hundred-row list.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                TextField("Search movies", text: $listSearch)
                if !listSearch.isEmpty {
                    Button {
                        listSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.rControl).fill(Theme.fill))
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
            if !playing.isEmpty {
                Section("In theaters now") { ForEach(playing) { movieRow($0) } }
            }
            if !dated.isEmpty {
                Section("Coming soon") { ForEach(dated) { movieRow($0) } }
            }
            if !undated.isEmpty {
                Section("Date to be announced") { ForEach(undated) { movieRow($0) } }
            }
            if playing.isEmpty, dated.isEmpty, undated.isEmpty, !listSearch.isEmpty {
                Text("No titles match \"\(listSearch)\".")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
    }

    private func movieRow(_ movie: Movie) -> some View {
        let mine = isMine(movie)
        return HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(movie.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if mine {
                        // The app-wide "saved" glyph — a capsule badge here
                        // crushed the title on small phones.
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.marquee)
                            .accessibilityLabel("On your list")
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
                // No Tickets for a film with no release date anywhere — the
                // sheet could only dead-end.
                if movie.tmdbID > 0, movie.isReleased || releaseDate(movie) != nil {
                    PillButton(title: "Showtimes", systemImage: "ticket", style: .outlined) {
                        activeSheet = .tickets(movie, movie.isReleased ? nil : releaseDate(movie))
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
        // The row IS a button (opens the movie) — VoiceOver must hear that.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { detailMovie = movie }
        .listRowBackground(Theme.background)
    }

    /// One verb everywhere: "In theaters now" or "Opens <day>" — the month
    /// cards use the same pair, so the two modes never disagree.
    private func dateLine(_ movie: Movie) -> String {
        if movie.isReleased { return "In theaters now" }
        if let date = releaseDate(movie) {
            return "Opens \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        }
        return "Coming soon"
    }

    // MARK: - Month mode

    /// Pageable range: current month through a year out (each month's
    /// releases are fetched on arrival), or further if something's already
    /// marked beyond that.
    private func monthBounds(_ days: [Date: [Movie]]) -> (lower: Date, upper: Date) {
        let lower = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let yearOut = cal.date(byAdding: .month, value: 11, to: lower)!
        let lastDate = days.keys.max() ?? lower
        let lastMarked = cal.date(from: cal.dateComponents([.year, .month], from: lastDate))!
        return (lower, max(yearOut, lastMarked))
    }

    private var monthBody: some View {
        // Computed once per render — every day cell reads from this copy.
        let days = byDay
        return ScrollView {
            VStack(spacing: 16) {
                monthGrid(days)
                if let day = selectedDay, let films = days[day], !films.isEmpty {
                    posterStrip(title: cal.isDateInToday(day)
                                    ? "Today — in theaters now"
                                    : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                                films, day: day)
                } else if days.isEmpty {
                    Text("No dated releases yet — check the List view.")
                        .font(.caption).foregroundStyle(Theme.gray).padding(.top, 4)
                } else if monthLoading {
                    ProgressView().padding(.top, 4)
                } else if !days.keys.contains(where: {
                    cal.isDate($0, equalTo: visibleMonth, toGranularity: .month)
                }) {
                    // An empty month — don't tell the user to tap a
                    // highlighted day when there isn't one.
                    Text(scope == .mine
                         ? "Nothing from your Want to Watch lands in \(visibleMonth.formatted(.dateTime.month(.wide)))."
                         : "Nothing announced for \(visibleMonth.formatted(.dateTime.month(.wide))) yet — check back soon.")
                        .font(.caption).foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32).padding(.top, 4)
                } else {
                    Text("Tap a highlighted day to see what's playing.")
                        .font(.caption).foregroundStyle(Theme.gray).padding(.top, 4)
                }
                if !undatedComing.isEmpty { posterStrip(title: "Date to be announced", undatedComing) }
                // Next week can look sparse until theaters publish it — say
                // why, so an empty Friday doesn't read as "nothing's showing".
                if hasLocalData, localDays.isEmpty {
                    Text("No theaters found near \(zipcode) within \(radius) mi — try widening your radius.")
                        .font(.caption2)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else if !nowPlaying.isEmpty,
                   cal.isDate(visibleMonth, equalTo: Date(), toGranularity: .month) {
                    // Verified live: big chains publish ~2 weeks of showtimes,
                    // but independents (Metrograph, Film Forum, IFC…) often
                    // post only ~3 days ahead — a blank day next weekend can
                    // still gain a one-off screening closer to the date.
                    Text("Days fill in as theaters post showtimes — chains publish a week or two out, indie theaters often just a few days.")
                        .font(.caption2)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func monthGrid(_ days: [Date: [Movie]]) -> some View {
        let start = cal.date(from: cal.dateComponents([.year, .month], from: visibleMonth))!
        let daysInMonth = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let firstWeekday = cal.component(.weekday, from: start)
        let leadingBlanks = (firstWeekday - cal.firstWeekday + 7) % 7
        let cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
            + (0..<daysInMonth).map { cal.date(byAdding: .day, value: $0, to: start) }
        let bounds = monthBounds(days)
        let weekdays = Self.weekdaySymbols.rotated(by: cal.firstWeekday - 1)

        let offMonth = !cal.isDate(start, equalTo: Date(), toGranularity: .month)
        return VStack(spacing: 10) {
            HStack {
                monthArrow("chevron.left", label: "Previous month",
                           enabled: start > bounds.lower) { step(-1) }
                Spacer()
                HStack(spacing: 8) {
                    Text(start.formatted(.dateTime.month(.wide).year())).font(.headline)
                    // Paged away? One tap home to today's in-theaters cell.
                    if offMonth {
                        Button {
                            Haptics.tap()
                            withAnimation(.snappy) {
                                visibleMonth = Date()
                                let today = cal.startOfDay(for: Date())
                                selectedDay = days[today] != nil ? today : firstReleaseDay(in: Date())
                            }
                        } label: {
                            Text("Today")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.marquee)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.marqueeSoft))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                monthArrow("chevron.right", label: "Next month",
                           enabled: start < bounds.upper) { step(1) }
            }
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(.caption2.weight(.semibold)).foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    dayCell(day, films: day.map { days[cal.startOfDay(for: $0)] ?? [] } ?? [])
                }
            }
        }
        .screenHPadding()
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, films: [Movie]) -> some View {
        if let day {
            let key = cal.startOfDay(for: day)
            let mineHere = films.contains(where: isMine)
            let count = films.count
            let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
            let isToday = cal.isDateInToday(day)
            // A film OPENING here (its release day) is the day's event —
            // marked distinctly from films merely showing.
            let opensHere = films.contains {
                releaseDate($0).map { cal.isDate($0, inSameDayAs: key) } == true
            }
            Button {
                if count > 0 { Haptics.tap(); selectedDay = key }
            } label: {
                VStack(spacing: 4) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.caption.weight(count > 0 ? .bold : .regular))
                        .foregroundStyle(opensHere ? Theme.marquee
                                         : count > 0 ? Theme.ink : Theme.gray.opacity(0.6))
                    // The day's lead film as a mini poster (mine first — byDay
                    // orders your titles ahead) — the grid reads like a marquee,
                    // not a page of dots. Dot fallback when there's no artwork.
                    if count > 0, let poster = films.first?.posterURL {
                        dayPosterThumb(poster, mine: mineHere, opens: opensHere, extra: count - 1)
                    } else {
                        Circle()
                            .fill(count > 0
                                  ? (mineHere ? Theme.marquee : Theme.gray.opacity(0.55))
                                  : .clear)
                            .frame(width: 5, height: 5)
                            .frame(height: 33)   // rows stay aligned with poster cells
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Theme.marqueeSoft : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isToday ? Theme.marquee.opacity(0.5) : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            // Always name the date (an empty label would hide it from VoiceOver);
            // add the release count when there is one.
            .accessibilityLabel(count > 0
                ? "\(day.formatted(.dateTime.month().day())), \(count) film\(count == 1 ? "" : "s")\(opensHere ? ", new release" : "")\(mineHere ? ", on your list" : "")"
                : day.formatted(.dateTime.month().day()))
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 58)
        }
    }

    /// 22×33 poster thumbnail for a calendar day. A gold ★ marks a day
    /// something OPENS (vs merely keeps showing). YOURS is unmistakable:
    /// full-strength artwork, gold ring, and a gold bookmark riding the top
    /// corner (the app-wide "saved" glyph). General releases render dimmed
    /// behind a hairline. "+N" when more films share the day.
    private func dayPosterThumb(_ url: URL, mine: Bool, opens: Bool, extra: Int) -> some View {
        CachedAsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(Theme.gray.opacity(0.18))
        }
        .frame(width: 22, height: 33)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // A dark scrim, not element opacity: opacity LIGHTENS artwork against
        // the cream light-mode background, erasing the yours-vs-releasing
        // contrast. A scrim reads as "dimmed" in both rooms.
        .overlay(RoundedRectangle(cornerRadius: 4)
            .fill(.black.opacity(mine ? 0 : 0.38)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(mine ? Theme.marquee : Theme.hairline, lineWidth: mine ? 1.4 : 1))
        .overlay(alignment: .topTrailing) {
            if mine {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.marquee)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: 3, y: -3)
            }
        }
        .overlay(alignment: .topLeading) {
            // A release opens on this day — the star says "premiere", apart
            // from every day it merely keeps showing.
            if opens {
                Image(systemName: "star.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.marquee)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .offset(x: -3, y: -3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surface2))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .offset(x: 5, y: 4)
            }
        }
    }

    private func monthArrow(_ icon: String, label: String, enabled: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(enabled ? Theme.marquee : Theme.gray.opacity(0.35))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func step(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        Haptics.tap()
        withAnimation(.snappy) {
            visibleMonth = next
            selectedDay = firstReleaseDay(in: next)
        }
    }

    /// "In theaters" / "Opens Aug 21" / "Early screening" — what this film is
    /// doing on the strip's day. A verified showing BEFORE the official date
    /// is a preview, and saying "Opens Aug 21" on a card sitting on Aug 17
    /// would read as a contradiction.
    private func statusCaption(for movie: Movie, on day: Date?) -> String {
        if let opening = releaseDate(movie), let day,
           cal.isDate(day, inSameDayAs: opening) {
            // Its actual premiere day — even for a film TMDB already counts
            // as released (openings must keep their moment ON the day).
            return cal.isDateInToday(opening) ? "Opens today"
                : "Opens \(opening.formatted(.dateTime.month(.abbreviated).day()))"
        }
        if movie.isReleased { return "In theaters" }
        guard let opening = releaseDate(movie) else { return "Coming soon" }
        if let day, cal.startOfDay(for: day) < cal.startOfDay(for: opening) {
            return "Early screening"
        }
        return "Opens \(opening.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Compact poster card. My titles get a gold ring; general releases don't.
    /// `day` = the calendar day this strip shows, carried into Tickets so the
    /// showtimes sheet opens on the date the user was looking at.
    private func posterStrip(title: String, _ films: [Movie], day: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption.weight(.bold)).tracking(0.5)
                    .foregroundStyle(Theme.gray)
                Text("\(films.count)")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.marquee)
            }
            .screenHPadding()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(films) { movie in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterView(url: movie.posterURL, width: 104)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(isMine(movie) ? Theme.marquee : .clear, lineWidth: 2))
                                // The same rank/bookmark quick actions that
                                // ride every poster this size (UI law #1).
                                .overlay(alignment: .bottomTrailing) {
                                    ArtworkQuickActions(movie: movie, onLog: { logMovie = $0 })
                                        .font(.body)
                                        .padding(6)
                                }
                                .onTapGesture { detailMovie = movie }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { detailMovie = movie }
                                .accessibilityLabel(movie.title)
                            Text(movie.title)
                                .font(.caption.weight(.semibold)).lineLimit(2)
                                .frame(width: 104, alignment: .leading)
                            // A film can mark many days now — every card says
                            // whether it's playing, previewing, or coming.
                            Text(statusCaption(for: movie, on: day))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(movie.isReleased ? Theme.scoreGreen : Theme.marquee)
                            if movie.tmdbID > 0, movie.isReleased || releaseDate(movie) != nil {
                                // Card-width compact ticket button — PillButton's
                                // padding overflowed 104pt and truncated to "Tick…".
                                Button {
                                    activeSheet = .tickets(movie,
                                        day ?? (movie.isReleased ? nil : releaseDate(movie)))
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "ticket").font(.caption2)
                                        Text("Showtimes").font(.caption.weight(.semibold))
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
        // INSTANT first paint: the candidate list is already in the store's
        // cache — show it now, refine each title as its details land. The
        // old wait-for-everything path blocked the whole screen 2-3s.
        myMovies = Self.theaterCandidates(from: store)
        myLoaded = true
        await refineMine()
    }

    /// The watchlist titles worth showing on a theatrical calendar, straight
    /// from cached metadata (no network).
    private static func theaterCandidates(from store: RankingStore) -> [Movie] {
        let year = Calendar(identifier: .gregorian).component(.year, from: .now)
        return Array(store.watchlist
            .compactMap { store.movie($0.movieID) }
            .filter { $0.tmdbID > 0 }
            .filter { ($0.releaseYear ?? year) >= year - 1 }
            .sorted { ($0.releaseYear ?? 0) > ($1.releaseYear ?? 0) }
            .prefix(60))
    }

    /// Fill a paged-to month with its theatrical releases (the base
    /// /upcoming feed only covers the next few weeks). Deduped against
    /// everything already loaded; failures just leave the month as-is.
    private func loadMonth(_ month: Date) async {
        let comps = cal.dateComponents([.year, .month], from: month)
        let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
        guard !fetchedMonths.contains(key) else { return }
        fetchedMonths.insert(key)
        loadingMonths.insert(key)
        defer { loadingMonths.remove(key) }
        guard let extra = try? await TMDBService.shared.releases(in: month) else {
            // A flaky connection must not blank the month for the session —
            // un-mark it so paging back retries (same rule as the schedule
            // windows).
            fetchedMonths.remove(key)
            return
        }
        let known = Set(releases.map(\.tmdbID)).union(nowOut.map(\.tmdbID))
        releases += extra.filter { $0.tmdbID > 0 && !known.contains($0.tmdbID) }
    }

    /// One Gracenote lookup for the user's zip → which upcoming days each
    /// running film ACTUALLY plays. Best-effort: without a zip (or on any
    /// failure) the grid just marks running films on today only.
    /// The EXHAUSTIVE local slate: one Gracenote call returns every film with
    /// a posted showing near the zip. Each is resolved to a TMDB movie —
    /// against what's already loaded first, then a TMDB search — so "All
    /// releases" shows everything actually playing on each day, not just
    /// whatever TMDB's popularity chart happened to include.
    /// Fetch every 14-day schedule window needed to cover the given month
    /// (bounded to ~60 days out — theaters essentially never post further).
    /// Paging ahead triggers this, so future days populate in real time as
    /// soon as theaters publish them (advance sales included).
    private func ensureLocalCoverage(for month: Date) async {
        guard zipcode.count == 5 else { return }
        let today = cal.startOfDay(for: Date())
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)
        else { return }
        let firstDay = max(today, monthStart)
        guard firstDay <= monthEnd,
              let horizon = cal.date(byAdding: .day, value: 60, to: today),
              firstDay <= horizon else { return }
        let lastDay = min(monthEnd, horizon)
        let firstIndex = (cal.dateComponents([.day], from: today, to: firstDay).day ?? 0) / 14
        let lastIndex = (cal.dateComponents([.day], from: today, to: lastDay).day ?? 0) / 14
        for index in firstIndex...lastIndex {
            await loadLocalWindow(index: index)
        }
    }

    /// New zip or radius = new truth: drop everything verified and refetch.
    private func resetLocalData() {
        localDays = [:]
        localFilms = []
        fetchedWindows = []
        checkedZip = ""
        Task { await ensureLocalCoverage(for: visibleMonth) }
    }

    /// One aligned window (today + index×14 days): fetch the local schedule,
    /// resolve every listing, and MERGE into the verified-day map. Guarded
    /// by a location snapshot: a zip/radius change mid-flight must never
    /// merge the OLD location's schedule into the fresh state.
    private func loadLocalWindow(index: Int) async {
        guard zipcode.count == 5, !fetchedWindows.contains(index),
              let start = cal.date(byAdding: .day, value: index * 14,
                                   to: cal.startOfDay(for: Date()))
        else { return }
        let zip = zipcode
        let rad = radius
        func stillCurrent() -> Bool { zip == zipcode && rad == radius }
        fetchedWindows.insert(index)
        do {
            let schedule = try await ShowtimesService.shared.localSchedule(
                zipcode: zip, radius: rad, from: start)
            guard stillCurrent() else { return }
            // The schedule fetch runs concurrently with the TMDB pool loads;
            // resolution wants the pools (cheap matches beat searches), so
            // give them a moment to land before falling back to searches.
            // myMovies now seeds synchronously, so only the general pools
            // are worth a short wait before falling back to searches.
            for _ in 0..<50 where !releasesLoaded {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard stillCurrent() else { return }
            // Cheap first pass: normalized-title lookup over loaded movies —
            // including the FULL cached watchlist, so an older film you saved
            // (a rerelease, say) still resolves without a search.
            let watchlistMovies = store.watchlist.compactMap { store.movie($0.movieID) }
            let loadedIDs = Set((myMovies + nowOut + releases).map(\.tmdbID))
            var byTitle: [String: [Movie]] = [:]
            for m in (myMovies + nowOut + releases + watchlistMovies) where m.tmdbID > 0 {
                byTitle[LetterboxdImporter.normalize(m.title), default: []].append(m)
            }
            var extraIDs = Set(localFilms.map(\.tmdbID))
            // Split: pool matches apply instantly; the rest resolve via TMDB
            // searches IN PARALLEL (bounded) — sequentially this was the
            // slowest stretch of a cold month view.
            var unresolved: [ShowtimesService.LocalListing] = []
            for listing in schedule {
                let known = byTitle[LetterboxdImporter.normalize(listing.title)]?.first {
                    listing.year == nil || $0.releaseYear == nil
                        || abs($0.releaseYear! - listing.year!) <= 1
                }
                if let known {
                    localDays[known.tmdbID, default: []].formUnion(listing.days)
                } else {
                    unresolved.append(listing)
                }
            }
            if !unresolved.isEmpty {
                let resolved = await Self.resolveViaSearch(unresolved)
                guard stillCurrent() else { return }
                for (listing, movie) in resolved {
                    guard movie.tmdbID > 0 else { continue }
                    localDays[movie.tmdbID, default: []].formUnion(listing.days)
                    // Anything not already loaded joins the pool — whether it
                    // resolved from the watchlist cache or a search.
                    if !loadedIDs.contains(movie.tmdbID), extraIDs.insert(movie.tmdbID).inserted {
                        localFilms.append(movie)
                    }
                }
            }
            // Only the NEAR-TERM window unlocks exact-marks mode: if window 0
            // failed but a far window landed, flipping this would blank today
            // and this week (released films would mark only far days).
            if index == 0 { checkedZip = zip }
        } catch {
            // Failed windows may retry on the next visit — but a stale task
            // must not un-mark the NEW location's in-flight fetch.
            if stillCurrent() { fetchedWindows.remove(index) }
            SupabaseService.logSwallowed("theaterCalendar.localSchedule", error)
        }
    }

    /// Resolve listings to TMDB movies with a bounded parallel fan-out.
    private static func resolveViaSearch(
        _ listings: [ShowtimesService.LocalListing]
    ) async -> [(ShowtimesService.LocalListing, Movie)] {
        await withTaskGroup(of: (ShowtimesService.LocalListing, Movie?).self) { group in
            var iterator = listings.makeIterator()
            func addNext() {
                guard let listing = iterator.next() else { return }
                group.addTask {
                    let imported = LetterboxdImporter.ImportedTitle(
                        title: listing.title, year: listing.year)
                    // ONE unfiltered search, matched locally: theatrical
                    // listings can never be TV (drop negative ids), and
                    // year-compatible candidates get first refusal — same
                    // semantics as filtered-then-fallback, half the requests.
                    let all = ((try? await TMDBService.shared.search(
                        query: listing.title)) ?? []).filter { $0.tmdbID > 0 }
                    let compatible = all.filter {
                        listing.year == nil || $0.releaseYear == nil
                            || abs($0.releaseYear! - listing.year!) <= 1
                    }
                    let match = LetterboxdImporter.bestMatch(for: imported, in: compatible)
                        ?? LetterboxdImporter.bestMatch(for: imported, in: all)
                    return (listing, match)
                }
            }
            for _ in 0..<4 { addNext() }
            var result: [(ShowtimesService.LocalListing, Movie)] = []
            for await (listing, movie) in group {
                addNext()
                if let movie { result.append((listing, movie)) }
            }
            return result
        }
    }

    /// Want to Watch movies that are theater-relevant: released within the last
    /// ~4 months (still in theaters) or still upcoming. Only fetch exact dates
    /// for titles from roughly the current era.
    /// Refine the seeded candidates with full TMDB details (exact release
    /// dates), UPDATING the visible list per result — the grid sharpens live
    /// instead of blocking on the whole fan-out. Bounded to 6 in flight.
    private func refineMine() async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        let candidates = myMovies
        await withTaskGroup(of: Movie?.self) { group in
            var iterator = candidates.makeIterator()
            func addNext() {
                guard let movie = iterator.next() else { return }
                group.addTask { try? await TMDBService.shared.details(for: movie.tmdbID) }
            }
            for _ in 0..<6 { addNext() }
            for await refined in group {
                addNext()
                guard let refined else { continue }
                let date = refined.releaseDateFull.flatMap { DateFormatter.localDay.date(from: $0) }
                let keep = !refined.isReleased || (date.map { $0 >= cutoff } ?? true)
                if let index = myMovies.firstIndex(where: { $0.tmdbID == refined.tmdbID }) {
                    if keep { myMovies[index] = refined }
                    else { myMovies.remove(at: index) }   // left theaters long ago
                }
            }
        }
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
