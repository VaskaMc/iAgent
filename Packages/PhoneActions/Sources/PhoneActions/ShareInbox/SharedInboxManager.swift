import Foundation

public struct SharedInboxItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let sourceAppHint: String
    public let receivedAt: Date

    public init(id: UUID = UUID(), text: String, sourceAppHint: String, receivedAt: Date) {
        self.id = id
        self.text = text
        self.sourceAppHint = sourceAppHint
        self.receivedAt = receivedAt
    }
}

public enum SharedInboxError: Error, Equatable, Sendable {
    case emptyText
    case exceedsByteLimit(bytes: Int, maxBytes: Int)
    case invalidUTF8
}

/// Share Extension ile ana uygulama arasındaki App Group gelen kutusunu yönetir.
/// Ağır model çıkarımı burada çalışmaz; yalnızca UTF-8 metin ve 64 KB sınırı denetlenir.
public final class SharedInboxManager: @unchecked Sendable {
    public static let maxUTF8Bytes = 65_536

    private let inboxDirectory: URL
    private let lock = NSLock()

    public init(inboxDirectory: URL) {
        self.inboxDirectory = inboxDirectory
    }

    public static func defaultInboxDirectory() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.iagent.shared"
        ) {
            return groupURL.appendingPathComponent("Inbox", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("iAgentShareInbox", isDirectory: true)
    }

    public func enqueueUTF8Data(_ data: Data, sourceAppHint: String, now: Date) throws -> SharedInboxItem {
        guard data.count <= Self.maxUTF8Bytes else {
            throw SharedInboxError.exceedsByteLimit(bytes: data.count, maxBytes: Self.maxUTF8Bytes)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SharedInboxError.invalidUTF8
        }
        return try enqueueText(text, sourceAppHint: sourceAppHint, now: now)
    }

    public func enqueueText(_ text: String, sourceAppHint: String, now: Date) throws -> SharedInboxItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SharedInboxError.emptyText
        }
        let byteCount = trimmed.utf8.count
        guard byteCount <= Self.maxUTF8Bytes else {
            throw SharedInboxError.exceedsByteLimit(bytes: byteCount, maxBytes: Self.maxUTF8Bytes)
        }

        let item = SharedInboxItem(text: trimmed, sourceAppHint: sourceAppHint, receivedAt: now)
        try lock.withLock {
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
            let fileURL = inboxDirectory.appendingPathComponent("\(item.id.uuidString).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(item)
            try encoded.write(to: fileURL, options: [.atomic])
        }
        return item
    }

    public func pendingItems() throws -> [SharedInboxItem] {
        try lock.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: inboxDirectory.path) else { return [] }
            let files = try fm.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try files.compactMap { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(SharedInboxItem.self, from: data)
            }.sorted { $0.receivedAt < $1.receivedAt }
        }
    }

    public func markConsumed(id: UUID) throws {
        try lock.withLock {
            let fileURL = inboxDirectory.appendingPathComponent("\(id.uuidString).json")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
