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
    private(set) var undo: (() -> Void)?
    /// Tapping the toast follows through (e.g. open what you just ranked).
    private(set) var tap: (() -> Void)?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) { present(text, undo: nil, tap: nil, seconds: 2.4) }

    /// A reversible action gets a few extra seconds and an Undo button.
    func showUndo(_ text: String, undo: @escaping () -> Void) {
        present(text, undo: undo, tap: nil, seconds: 4.5)
    }

    /// A toast you can tap to go somewhere — shows a chevron and stays a beat
    /// longer (e.g. "Added to Watched · tap to view" → the movie page).
    func showTap(_ text: String, action: @escaping () -> Void) {
        present(text, undo: nil, tap: action, seconds: 4.0)
    }

    private func present(_ text: String, undo: (() -> Void)?,
                         tap: (() -> Void)?, seconds: Double) {
        hideTask?.cancel()
        withAnimation(.snappy) { message = text; self.undo = undo; self.tap = tap }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self.message = nil; self.undo = nil; self.tap = nil }
        }
    }

    func performUndo() {
        let action = undo
        hideTask?.cancel()
        Haptics.tap()
        withAnimation(.snappy) { message = nil; undo = nil; tap = nil }
        action?()
    }

    func performTap() {
        guard let action = tap else { return }
        hideTask?.cancel()
        Haptics.tap()
        withAnimation(.snappy) { message = nil; undo = nil; tap = nil }
        action()
    }

    /// The standard write-failure line.
    func saveFailed() {
        Haptics.error()
        show("Couldn't save — check your connection")
    }
}

/// Floating capsule above the tab bar; never intercepts touches except for
/// an Undo button.
struct ToastOverlay: View {
    @State private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let message = center.message {
                HStack(spacing: 14) {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if center.undo != nil {
                        Button("Undo") { center.performUndo() }
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.marquee)
                            .buttonStyle(.plain)
                    } else if center.tap != nil {
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.marquee)
                    }
                }
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
                // Only an actionable toast (Undo button or tap-to-open) catches
                // touches; a plain toast lets taps fall through to the UI below.
                .allowsHitTesting(center.undo != nil || center.tap != nil)
                .onTapGesture { center.performTap() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Toast window (always on top)

/// The toast lives in its OWN passthrough UIWindow at alert level, so it
/// renders above every sheet and full-screen cover. Mounted as a plain
/// overlay on RootTabView it drew UNDER presented sheets — a failed save
/// inside a sheet (Your Details, Save-to-List, Rewatch…) toasted invisibly,
/// which reads as success and loses the user's edit.
@MainActor
enum ToastWindow {
    private static var window: PassthroughWindow?

    /// Idempotent — call once the scene exists (RootTabView.onAppear).
    static func install() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first else { return }
        let host = UIHostingController(rootView: ToastOverlay())
        host.view.backgroundColor = .clear
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .alert
        w.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
        syncAppearance()
    }

    /// A separate window doesn't inherit SwiftUI's preferredColorScheme —
    /// mirror the in-app appearance setting (called again when it changes).
    static func syncAppearance() {
        let raw = UserDefaults.standard.string(forKey: "cini.appearance") ?? "dark"
        window?.overrideUserInterfaceStyle = switch raw {
        case "light": .light
        case "system": .unspecified
        default: .dark
        }
    }
}

/// Transparent window that only intercepts the toast's actionable content
/// (Undo / tap-to-open); everything else falls through to the app below.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let view = super.hitTest(point, with: event) else { return nil }
        return view === rootViewController?.view ? nil : view
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
