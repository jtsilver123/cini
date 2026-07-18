import Foundation

/// The desktop-transfer handoff, tracked app-wide. The import screen mints a
/// transfer code, but the upload from the computer can land while the user is
/// anywhere else in the app (or after the phone locked and the screen's own
/// poll died). The pending code persists here so RootTabView's watcher can
/// spot the landed upload and auto-open the import — the handoff needs no
/// babysitting.
@MainActor
enum ImportTransfer {
    private static let codeKey = "import.pendingCode"
    private static let dateKey = "import.pendingCodeAt"
    /// Matches the server's 30-minute code window.
    static let ttl: TimeInterval = 30 * 60

    /// True while the import screen itself is open and polling — the
    /// app-wide watcher stands down so the same upload isn't handled twice.
    static var viewIsHandling = false

    /// The transfer code still worth watching, if any (expired codes clear
    /// themselves).
    static var pendingCode: String? {
        guard let code = UserDefaults.standard.string(forKey: codeKey) else { return nil }
        let mintedAt = UserDefaults.standard.double(forKey: dateKey)
        guard Date().timeIntervalSince1970 - mintedAt < ttl else {
            clear()
            return nil
        }
        return code
    }

    static func begin(_ code: String) {
        UserDefaults.standard.set(code, forKey: codeKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: dateKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: codeKey)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }
}
