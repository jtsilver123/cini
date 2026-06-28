import SwiftUI

/// Searchable college picker for the profile. Returns the chosen school (or nil
/// to clear it). A fixed canonical list keeps campus leaderboards consistent.
struct SchoolPickerView: View {
    /// The currently-set school, highlighted with a checkmark.
    var current: String?
    var onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [String] { Colleges.search(query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                    TextField("Search your school", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .padding(.horizontal, 16).padding(.top, 8)

                List {
                    if current != nil {
                        Button {
                            onSelect(nil); dismiss()
                        } label: {
                            Label("Remove my school", systemImage: "xmark")
                                .foregroundStyle(Theme.velvet)
                        }
                        .listRowBackground(Theme.background)
                    }
                    ForEach(results, id: \.self) { name in
                        Button {
                            onSelect(name); dismiss()
                        } label: {
                            HStack {
                                Text(name).foregroundStyle(Theme.ink)
                                Spacer()
                                if name == current {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.marquee)
                                }
                            }
                        }
                        .listRowBackground(Theme.background)
                    }
                    if results.isEmpty {
                        Text("No match yet. We add schools as people ask. Email jtsilver123@gmail.com with yours.")
                            .font(.subheadline).foregroundStyle(Theme.gray)
                            .listRowBackground(Theme.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
            .background(Theme.background)
            .navigationTitle("Your school")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
