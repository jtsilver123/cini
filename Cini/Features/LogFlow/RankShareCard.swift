import SwiftUI
import RankingEngine

// The shareable "ticket" — rendered to an image for the share sheet
// (IG stories, iMessage). Same admit-one language as the in-app result
// card, sized for a story crop.

struct RankShareCard: View {
    let movie: Movie
    let scored: ScoredItem<Int>
    let poster: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            Text("ADMIT ONE · CINI")
                .font(.system(size: 11, weight: .bold))
                .tracking(4)
                .foregroundStyle(Theme.gray)
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 210, height: 315)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(movie.title)
                .font(Theme.serif(26))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            HStack(spacing: 16) {
                (Text("Ranked ") + Text("#\(scored.rank)").foregroundStyle(Theme.gold))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                ScoreBadge(score: scored.score, size: 52)
            }
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                .foregroundStyle(Theme.hairline)
                .frame(height: 1)
            Text("cini")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.marquee)
        }
        .padding(28)
        .frame(width: 360)
        .background(Theme.background)
    }
}
