import SwiftUI

/// Chronological diary — every watch (including rewatches) grouped by
/// month, newest first. Letterboxd's diary, Cini-flavored.
struct DiaryScreen: View {
    let userID: UUID?
    let isSelf: Bool

    @Environment(RankingStore.self) private var store

    @State private var watches: [WatchRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var loaded = false
    @State private var detailMovie: Movie?

    /// [(month header, entries)] — "June 2026" etc.
    private var grouped: [(month: String, rows: [WatchRow])] {
        var order: [String] = []
        var buckets: [String: [WatchRow]] = [:]
        for watch in watches {
            let month = monthLabel(watch.watchedOn)
            if buckets[month] == nil { order.append(month) }
            buckets[month, default: []].append(watch)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        List {
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.background)
            } else if watches.isEmpty {
                Text(isSelf ? "Every movie and show you rank lands here — rewatches too. Rank one to start your diary."
                            : "No diary entries to show yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .listRowBackground(Theme.background)
            }
            ForEach(grouped, id: \.month) { group in
                Section {
                    ForEach(group.rows) { watch in
                        if let movie = movies[watch.movieId] ?? store.movie(watch.movieId) {
                            diaryRow(watch, movie: movie)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.cache(movie)
                                    detailMovie = movie
                                }
                                .listRowBackground(Theme.background)
                        }
                    }
                } header: {
                    Text(group.month.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.5)
                        .foregroundStyle(Theme.gray)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Diary")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .task {
            guard let userID else { loaded = true; return }
            watches = (try? await SupabaseService.shared.watches(of: userID)) ?? []
            let ids = Array(Set(watches.map(\.movieId)))
            let rows = (try? await SupabaseService.shared.movies(ids: ids)) ?? []
            for row in rows { movies[row.tmdbId] = row.asMovie }
            loaded = true
        }
    }

    private func diaryRow(_ watch: WatchRow, movie: Movie) -> some View {
        HStack(spacing: 12) {
            Text(dayLabel(watch.watchedOn))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.marquee)
                .frame(width: 30)
            PosterView(url: movie.posterURL, width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let location = watch.watchedWhere {
                        Label(location == "theater" ? "In theaters" : "At home",
                              systemImage: location == "theater" ? "ticket" : "house")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
            }
            Spacer()
            if let item = store.scoredItem(for: movie.tmdbID), isSelf {
                ScoreBadge(score: item.score, size: 36)
            }
        }
        .padding(.vertical, 4)
    }

    private func monthLabel(_ day: String) -> String {
        guard let date = DateFormatter.posixDay.date(from: day) else { return day }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private func dayLabel(_ day: String) -> String {
        guard let date = DateFormatter.posixDay.date(from: day) else { return "" }
        return date.formatted(.dateTime.day())
    }
}
