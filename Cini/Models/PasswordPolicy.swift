import Foundation

/// One source of truth for the password rule so the sign-up screen and the
/// "change password" settings screen can't drift. One simple rule: at least
/// 8 characters. (Both screens show it as a live checklist.)
enum PasswordPolicy {
    static func hasLength(_ p: String) -> Bool { p.count >= 8 }

    static func isValid(_ p: String) -> Bool { hasLength(p) }

    static let lengthRule = "At least 8 characters"
    static let summary = "Use at least 8 characters."
}
