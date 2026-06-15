import Foundation

/// One source of truth for password rules so the sign-up screen and the
/// "change password" settings screen can't drift. (They had: sign-up required
/// 8–20 chars + complexity while settings still accepted 6.) Both show these
/// as a live checklist.
enum PasswordPolicy {
    static func hasLength(_ p: String) -> Bool { (8...20).contains(p.count) }

    static func hasMix(_ p: String) -> Bool {
        let letter = p.contains { $0.isLetter }
        let number = p.contains { $0.isNumber }
        let special = p.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
        return letter && number && special
    }

    static func isValid(_ p: String) -> Bool { hasLength(p) && hasMix(p) }

    static let lengthRule = "8–20 characters"
    static let mixRule = "Letters, numbers, and a special character"
    static let summary = "8–20 characters with letters, numbers, and a special character."
}
