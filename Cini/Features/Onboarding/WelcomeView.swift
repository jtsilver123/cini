import SwiftUI

/// The front door (Beli-style): a value-prop carousel shown BEFORE we ask for
/// anything, then "Get started" / "Sign in". Branding is the cinema palette —
/// marquee gold on the house-lights-down background.
struct WelcomeView: View {
    @State private var page = 0
    @State private var showAuth = false
    @State private var startInSignUp = true

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            // Warm marquee glow up top.
            RadialGradient(colors: [Theme.marquee.opacity(0.16), .clear],
                           center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    firstSlide.tag(0)
                    slide("rectangle.on.rectangle.angled",
                          "No star ratings. Ever.",
                          "Answer one question — which did you like more? — and Cini builds your perfectly ordered list, with scores from your own taste.").tag(1)
                    slide("person.2.fill",
                          "Better with friends",
                          "See what friends thought before you commit a night to it, get recs that match your taste, and race the leaderboard.").tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .animation(.snappy, value: page)

                VStack(spacing: 12) {
                    Button {
                        startInSignUp = true
                        showAuth = true
                    } label: {
                        Text("Get started")
                            .font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(Capsule().fill(Theme.velvet))
                    }
                    .buttonStyle(.plain)

                    Button {
                        startInSignUp = false
                        showAuth = true
                    } label: {
                        Text("I already have an account")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .fullScreenCover(isPresented: $showAuth) {
            AuthView(startInSignUp: startInSignUp)
        }
    }

    /// Slide 1 leads with the marquee wordmark.
    private var firstSlide: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("cini")
                .font(Theme.display(72))
                .foregroundStyle(Theme.marquee)
            Text("EVERY FILM · RANKED")
                .font(.system(size: 12, weight: .bold)).tracking(4)
                .foregroundStyle(Theme.gray)
            Text("Rank every movie and show you watch — and find your next obsession.")
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.top, 14)
            Spacer()
            Spacer()
        }
    }

    private func slide(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(Theme.marquee)
            Text(title)
                .font(Theme.serif(30))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
            Spacer()
        }
    }
}
