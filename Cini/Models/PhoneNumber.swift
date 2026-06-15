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

    /// Validity for a given country dial code: strict NANP for +1, a plausible
    /// length elsewhere (national numbers run ~6–14 digits). The server matches
    /// on the last 10 digits, so this just catches obvious junk.
    static func isValid(_ raw: String, dial: String) -> Bool {
        if dial == "+1" { return isValid(raw) }
        let count = digits(raw).count
        return count >= 6 && count <= 14
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

/// A country dial code for the sign-up phone picker (Beli lets you change it).
/// `+1` covers the US/Canada NANP; the rest are common international codes.
struct CountryCode: Identifiable, Hashable {
    var id: String { flag + dial }
    let flag: String
    let name: String
    let dial: String

    static let common: [CountryCode] = [
        CountryCode(flag: "🇺🇸", name: "United States", dial: "+1"),
        CountryCode(flag: "🇬🇧", name: "United Kingdom", dial: "+44"),
        CountryCode(flag: "🇨🇦", name: "Canada", dial: "+1"),
        CountryCode(flag: "🇦🇺", name: "Australia", dial: "+61"),
        CountryCode(flag: "🇮🇳", name: "India", dial: "+91"),
        CountryCode(flag: "🇮🇪", name: "Ireland", dial: "+353"),
        CountryCode(flag: "🇲🇽", name: "Mexico", dial: "+52"),
        CountryCode(flag: "🇧🇷", name: "Brazil", dial: "+55"),
        CountryCode(flag: "🇫🇷", name: "France", dial: "+33"),
        CountryCode(flag: "🇩🇪", name: "Germany", dial: "+49"),
        CountryCode(flag: "🇪🇸", name: "Spain", dial: "+34"),
        CountryCode(flag: "🇮🇹", name: "Italy", dial: "+39"),
        CountryCode(flag: "🇳🇱", name: "Netherlands", dial: "+31"),
        CountryCode(flag: "🇸🇪", name: "Sweden", dial: "+46"),
        CountryCode(flag: "🇯🇵", name: "Japan", dial: "+81"),
        CountryCode(flag: "🇰🇷", name: "South Korea", dial: "+82"),
        CountryCode(flag: "🇨🇳", name: "China", dial: "+86"),
        CountryCode(flag: "🇸🇬", name: "Singapore", dial: "+65"),
        CountryCode(flag: "🇵🇭", name: "Philippines", dial: "+63"),
        CountryCode(flag: "🇦🇪", name: "United Arab Emirates", dial: "+971"),
        CountryCode(flag: "🇳🇬", name: "Nigeria", dial: "+234"),
        CountryCode(flag: "🇿🇦", name: "South Africa", dial: "+27"),
        CountryCode(flag: "🇳🇿", name: "New Zealand", dial: "+64"),
    ]

    static let usDefault = common[0]
}
