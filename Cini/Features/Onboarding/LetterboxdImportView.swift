import SwiftUI
import UniformTypeIdentifiers

/// Letterboxd CSV / IMDb ratings import. Parsed titles are matched against
/// TMDB and seed the "Movies you may have seen" queue — the user still ranks
/// each one through the comparison flow (we never import star ratings).
struct LetterboxdImportView: View {
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var imported: [ImportedTitle] = []
    @State private var matching = false

    struct ImportedTitle: Identifiable {
        let id = UUID()
        let title: String
        let year: Int?
        var match: Movie?
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.teal)
                Text("Import your history")
                    .font(Theme.serif(28))
                Text("Upload a Letterboxd export (watched.csv) or IMDb ratings CSV. We'll queue everything under \"Movies you may have seen\" so you can rank them your way.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)

                PillButton(title: "Choose CSV file", systemImage: "doc") {
                    showPicker = true
                }

                if matching {
                    ProgressView("Matching \(imported.count) titles against TMDB…")
                }

                if !imported.isEmpty && !matching {
                    let matched = imported.filter { $0.match != nil }.count
                    Text("Matched \(matched) of \(imported.count) titles")
                        .font(.subheadline.weight(.semibold))
                    PillButton(title: "Done") { dismiss() }
                }

                Spacer()
            }
            .padding(28)
            .background(Theme.background)
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) { result in
                if case .success(let url) = result {
                    Task { await importCSV(from: url) }
                }
            }
        }
    }

    private func importCSV(from url: URL) async {
        guard url.startAccessingSecurityScopedResource(),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        imported = Self.parse(csv: text)
        matching = true
        // Match a bounded batch immediately; the rest match lazily later.
        for index in imported.prefix(40).indices {
            let entry = imported[index]
            let results = (try? await TMDBService.shared.search(query: entry.title, year: entry.year)) ?? []
            if let best = results.first {
                imported[index].match = best
                store.cache(best)
            }
        }
        matching = false
    }

    /// Parses both Letterboxd (Date,Name,Year,Letterboxd URI) and IMDb
    /// (Const,Your Rating,...,Title,...,Year) export shapes.
    static func parse(csv: String) -> [ImportedTitle] {
        let lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let header = splitCSVRow(headerLine).map { $0.lowercased() }

        let titleIndex = header.firstIndex { $0 == "name" || $0 == "title" }
        let yearIndex = header.firstIndex { $0 == "year" }
        guard let titleIndex else { return [] }

        return lines.dropFirst().compactMap { line in
            let fields = splitCSVRow(line)
            guard fields.indices.contains(titleIndex) else { return nil }
            let title = fields[titleIndex].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let year = yearIndex.flatMap { fields.indices.contains($0) ? Int(fields[$0]) : nil }
            return ImportedTitle(title: title, year: year)
        }
    }

    /// Minimal CSV field splitter with quoted-field support.
    static func splitCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in row {
            switch char {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}
