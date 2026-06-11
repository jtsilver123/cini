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
