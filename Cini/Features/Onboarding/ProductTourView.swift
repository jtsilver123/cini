import SwiftUI

/// A quick "how Cini works" tour shown once, right after onboarding finishes
/// (Beli does the same). A paged card carousel over the app — kept short: four
/// slides mapping to the four things people do here. Presented as an overlay
/// (not a cover) so it can't be dropped during the onboarding→app transition.
struct ProductTourView: View {
    var onDone: () -> Void

    @State private var page = 0

    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(icon: "rectangle.on.rectangle.angled",
              title: "Rank what you watch",
              body: "Search any movie or show, tap how you felt, and a couple of quick “which did you like more?” taps slot it exactly where it belongs."),
        Slide(icon: "list.number",
              title: "Your taste, scored",
              body: "Your Lists keeps everything you've ranked, each scored out of 10 — from your own order, not a crowd of strangers."),
        Slide(icon: "person.2.fill",
              title: "Better with friends",
              body: "Your feed fills with friends' ranks and recs. Follow people, see their takes, and trade what to watch next."),
        Slide(icon: "sparkles",
              title: "Find your next watch",
              body: "Rec Scores predict how much you'll like something you haven't seen, and the Leaderboard ranks the whole community."),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { i, slide in
                        slideView(slide).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 360)

                pageDots.padding(.bottom, 22)

                Button {
                    if page < slides.count - 1 {
                        withAnimation(.snappy) { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < slides.count - 1 ? "Next" : "Start ranking")
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Capsule().fill(Theme.velvet))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
            }
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.cardShadow, radius: 24, y: 10)
            )
            .padding(.horizontal, 22)
        }
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.marqueeSoft).frame(width: 110, height: 110)
                Image(systemName: slide.icon)
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.marquee)
            }
            Text(slide.title)
                .font(Theme.serif(28))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(slide.body)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(slides.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.marquee : Theme.gray.opacity(0.4))
                    .frame(width: i == page ? 22 : 7, height: 7)
                    .animation(.snappy, value: page)
            }
        }
    }

    private func finish() {
        Haptics.tap()
        onDone()
    }
}
