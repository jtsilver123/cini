import Contacts

/// One-shot contacts → email list for "find friends". Only email
/// addresses are read, only to ask the server which belong to members;
/// nothing is stored.
enum ContactsEmails {
    static func fetch() async -> [String] {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return [] }
        let request = CNContactFetchRequest(keysToFetch: [CNContactEmailAddressesKey as CNKeyDescriptor])
        var emails: [String] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            for address in contact.emailAddresses {
                emails.append((address.value as String).lowercased())
            }
        }
        return Array(Set(emails)).filter { $0.contains("@") }
    }
}

/// A contact with a name + phone, for the Beli-style "invite your contacts"
/// list (tap Invite → a prefilled text message). Read once, never stored.
struct PhoneContact: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let phone: String
}

enum ContactsList {
    static func fetch() async -> [PhoneContact] {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var out: [PhoneContact] = []
        var seen = Set<String>()
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty, let phone = contact.phoneNumbers.first?.value.stringValue,
                  seen.insert(name.lowercased()).inserted else { return }
            out.append(PhoneContact(name: name, phone: phone))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

