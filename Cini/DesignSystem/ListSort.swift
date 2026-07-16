import SwiftUI

/// The one sort model every movie list uses — yours and anyone else's.
/// Exactly three metrics, nothing more.
enum ListSortMetric: String, CaseIterable {
    case score = "Score", dateAdded = "Date added", runtime = "Runtime"

    var icon: String {
        switch self {
        case .score: return "star"
        case .dateAdded: return "calendar"
        case .runtime: return "clock"
        }
    }
    var descLabel: String {
        switch self {
        case .score: return "Highest first"
        case .dateAdded: return "Newest first"
        case .runtime: return "Longest first"
        }
    }
    var ascLabel: String {
        switch self {
        case .score: return "Lowest first"
        case .dateAdded: return "Oldest first"
        case .runtime: return "Shortest first"
        }
    }
}

/// The shared sort control: current metric + direction arrow, tapping opens a
/// menu to pick one of the three metrics and the order. Used on My Lists and
/// on every member's list, so they all behave the same.
struct ListSortMenu: View {
    @Binding var metric: ListSortMetric
    @Binding var descending: Bool

    var body: some View {
        Menu {
            Picker("Sort by", selection: $metric) {
                ForEach(ListSortMetric.allCases, id: \.self) { m in
                    Label(m.rawValue, systemImage: m.icon).tag(m)
                }
            }
            Divider()
            Picker("Order", selection: $descending) {
                Label(metric.descLabel, systemImage: "arrow.down").tag(true)
                Label(metric.ascLabel, systemImage: "arrow.up").tag(false)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: descending ? "arrow.down" : "arrow.up").font(.caption.weight(.bold))
                Text(metric.rawValue).font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Theme.marquee)
        }
    }
}
