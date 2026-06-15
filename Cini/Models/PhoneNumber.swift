import Foundation

/// US/NANP phone helpers: validate what someone typed (Beli shows "invalid
/// number" on random digits) and format it for display. The app collects a
/// US number behind a fixed "+1", so validation is NANP: 10 digits with the
/// area code and exchange both starting 2–9. The server stores the last 10
/// digits as the match key, so formatting here is purely cosmetic.
enum PhoneNumber {
    /// Digits only.
    static func digits(_ raw: String) -> String { raw.filter(\.isNumber) }

    /// The 10-digit national number, dropping a leading US "1" if present.
    /// `nil` if it isn't exactly 10 digits.
    static func national(_ raw: String) -> String? {
        var d = digits(raw)
        if d.count == 11, d.hasPrefix("1") { d.removeFirst() }
        return d.count == 10 ? d : nil
    }

    /// True only for a plausible US number: 10 digits, area code and exchange
    /// first digits both 2–9 (NANP rules). Catches obvious junk like 0000000000.
    static func isValid(_ raw: String) -> Bool {
        guard let n = national(raw) else { return false }
        let area = n[n.startIndex]
        let exchange = n[n.index(n.startIndex, offsetBy: 3)]
        return ("2"..."9").contains(area) && ("2"..."9").contains(exchange)
    }

    /// Progressive display formatting as digits are typed: "(555) 123-4567".
    /// Only formats up to 10 digits.
    static func formattedLive(_ raw: String) -> String {
        let d = String(digits(raw).prefix(10))
        switch d.count {
        case 0: return ""
        case 1...3: return "(\(d)"
        case 4...6: return "(\(d.prefix(3))) \(d.dropFirst(3))"
        default:    return "(\(d.prefix(3))) \(d.dropFirst(3).prefix(3))-\(d.dropFirst(6))"
        }
    }
}
