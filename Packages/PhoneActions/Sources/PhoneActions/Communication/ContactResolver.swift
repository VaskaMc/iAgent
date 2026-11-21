import Foundation
import AgentCore

#if canImport(Contacts)
import Contacts
#endif

public struct ContactCandidate: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        id: String,
        displayName: String,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public enum ContactChannel: String, Codable, Sendable, Equatable {
    case phoneOrSMS
    case email
}

public enum ContactResolutionOutcome: Equatable, Sendable {
    case resolved(candidate: ContactCandidate, selectedHandle: String)
    case disambiguationRequired(query: String, candidates: [ContactCandidate])
    case noMatchOfferSystemPicker(query: String)
    case permissionDeniedOfferSystemPicker(query: String)
}

public protocol ContactDirectoryProtocol: Sendable {
    func isAuthorized() async -> Bool
    func searchContacts(matching query: String) async throws -> [ContactCandidate]
}

public final class InMemoryContactDirectory: ContactDirectoryProtocol, @unchecked Sendable {
    public var authorized: Bool
    public var contacts: [ContactCandidate]

    public init(authorized: Bool = true, contacts: [ContactCandidate] = []) {
        self.authorized = authorized
        self.contacts = contacts
    }

    public func isAuthorized() async -> Bool {
        authorized
    }

    public func searchContacts(matching query: String) async throws -> [ContactCandidate] {
        let normQuery = TurkicTextNormalizer.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normQuery.isEmpty else { return [] }
        return contacts.filter { candidate in
            TurkicTextNormalizer.normalize(candidate.displayName).contains(normQuery)
        }
    }
}

#if canImport(Contacts)
public final class LiveContactsDirectory: ContactDirectoryProtocol, @unchecked Sendable {
    private let store = CNContactStore()
    public init() {}

    public func isAuthorized() async -> Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    public func searchContacts(matching query: String) async throws -> [ContactCandidate] {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        return matches.map { contact in
            let fullName = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return ContactCandidate(
                id: contact.identifier,
                displayName: fullName.isEmpty ? query : fullName,
                phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                emailAddresses: contact.emailAddresses.map { $0.value as String }
            )
        }
    }
}
#endif

/// Kişi adını tek başına gönderim adresi yapmaz; çoklu eşleşmede kullanıcı seçimi ister.
public final class ContactResolver: @unchecked Sendable {
    private let directory: ContactDirectoryProtocol

    public init(directory: ContactDirectoryProtocol) {
        self.directory = directory
    }

    public func resolve(query: String, channel: ContactChannel) async -> ContactResolutionOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .noMatchOfferSystemPicker(query: query)
        }

        guard await directory.isAuthorized() else {
            return .permissionDeniedOfferSystemPicker(query: trimmed)
        }

        do {
            let candidates = try await directory.searchContacts(matching: trimmed)
            let filtered = candidates.filter { candidate in
                switch channel {
                case .phoneOrSMS: return !candidate.phoneNumbers.isEmpty
                case .email: return !candidate.emailAddresses.isEmpty
                }
            }

            if filtered.isEmpty {
                return .noMatchOfferSystemPicker(query: trimmed)
            }
            if filtered.count > 1 {
                return .disambiguationRequired(query: trimmed, candidates: filtered)
            }

            let single = filtered[0]
            let handles = channel == .phoneOrSMS ? single.phoneNumbers : single.emailAddresses
            if handles.count > 1 {
                // Tek kişide birden fazla numara/e-posta varsa da kullanıcıya seçtirilir.
                return .disambiguationRequired(query: trimmed, candidates: [single])
            }
            return .resolved(candidate: single, selectedHandle: handles[0])
        } catch {
            return .noMatchOfferSystemPicker(query: trimmed)
        }
    }
}
