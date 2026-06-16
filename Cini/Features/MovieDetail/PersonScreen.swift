import SwiftUI

/// Cast/crew member page — pushed from a movie's Cast list. Photo, bio,
/// and their filmography (acted or directed, movies and shows), most
/// popular first, with the standard quick actions on every row.
struct PersonScreen: View {
    let member: CastMember

    @Environment(RankingStore.self) private var store

    @State private var details: TMDBService.PersonDetails?
    @State private var filmography: [Movie] = []
    @State private var loaded = false
    @State private var bioExpanded = false
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let bio = details?.biography, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bio)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink.opacity(0.9))
                            .lineLimit(bioExpanded ? nil : 4)
                        if bio.count > 220 {
                            Button(bioExpanded ? "Less" : "More") {
                                withAnimation(.snappy) { bioExpanded.toggle() }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Known for").font(.title3.weight(.bold))

                if !loaded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10).fill(Theme.fill)
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        }
                    }
                    .modifier(SkeletonPulse())
                } else if filmography.isEmpty {
                    Text("No titles found.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                }

                ForEach(filmography) { movie in
                    WatchlistRowView(movie: movie) {
                        logMovie = movie
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.cache(movie)
                        detailMovie = movie
                    }
                    Divider()
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
        .task {
            details = try? await TMDBService.shared.person(id: member.id)
            filmography = (try? await TMDBService.shared.filmography(personID: member.id)) ?? []
            for movie in filmography { store.cache(movie) }
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: details?.photoURL ?? member.photoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Theme.gray.opacity(0.2))
                    .overlay(Image(systemName: "person").foregroundStyle(Theme.gray))
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(member.name).font(Theme.serif(26))
                if let department = details?.knownForDepartment {
                    Text(department == "Acting" ? "Actor" : department)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                }
                if let character = member.character, !character.isEmpty {
                    Text(originTitle.isEmpty ? "as \(character)"
                                             : "as \(character) in \(originTitle)")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }

    /// The movie this page was opened from, for the "as <character>" line.
    var originTitle: String = ""
}
