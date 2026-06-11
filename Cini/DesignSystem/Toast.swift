import SwiftUI
import Observation

// MARK: - App-wide feedback: nothing fails silently

/// One toast at a time, bottom of the screen, auto-dismissing. Failures
/// must never be silent, and remote actions deserve a word back.
@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        hideTask?.cancel()
        withAnimation(.snappy) { message = text }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self.message = nil }
        }
    }

    /// The standard write-failure line.
    func saveFailed() {
        Haptics.error()
        show("Couldn't save — check your connection")
    }
}

/// Floating capsule above the tab bar; never intercepts touches.
struct ToastOverlay: View {
    @State private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = center.message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Theme.surface2)
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .shadow(color: Theme.cardShadow, radius: 12, y: 4)
                    )
                    .padding(.horizontal, 32)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Haptics, consistently

/// The rank flow always buzzed; now everything that changes state does.
enum Haptics {
    @MainActor static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
