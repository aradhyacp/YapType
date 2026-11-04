import Contacts
import EventKit
import Foundation

/// Names from Contacts (people and companies) and today's calendar events (titles, attendees). Read on launch and
/// hourly when Settings › Use Contacts and Calendar is on; used only to bias speech recognition, never stored.
enum NameSources {
    static func names() async -> [String] {
        var out: [String] = []
        let contacts = CNContactStore()
        if (try? await contacts.requestAccess(for: .contacts)) == true {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? contacts.enumerateContacts(with: req) { c, _ in
                for n in [c.givenName, c.familyName, c.nickname, c.organizationName, [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")] {
                    let t = n.trimmingCharacters(in: .whitespaces)
                    if t.count >= 3, t.first?.isLetter == true { out.append(t) }
                }
            }
        }
        let events = EKEventStore()
        if (try? await events.requestFullAccessToEvents()) == true {
            let start = Calendar.current.startOfDay(for: Date())
            let pred = events.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400 * 2), calendars: nil)
            for e in events.events(matching: pred) {
                if let t = e.title { out.append(contentsOf: TextRules.contextNames(t)) }
                for a in e.attendees ?? [] { if let n = a.name, n.count >= 3 { out.append(n) } }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }
}
