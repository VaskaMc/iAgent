import Foundation

/// iAgent içinde kalıcı olarak saklanan yerel kullanıcı notu.
public struct PersistentNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public let createdAt: Date
    public var updatedAt: Date
    public let sourceTaskId: UUID
    public var isDeleted: Bool

    public init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        sourceTaskId: UUID,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.sourceTaskId = sourceTaskId
        self.isDeleted = isDeleted
    }
}

public enum NoteStoreError: Error, Equatable, Sendable {
    case emptyContent
    case noteNotFound(UUID)
}

/// Yerel kalıcı not deposu sözleşmesi.
public protocol NoteStoreProtocol: Sendable {
    func createNote(content: String, sourceTaskId: UUID, now: Date) throws -> PersistentNote
    func undoCreate(noteId: UUID, now: Date) throws -> PersistentNote
    func searchNotes(query: String) throws -> [PersistentNote]
    func allActiveNotes() throws -> [PersistentNote]
    func reloadFromDisk() throws
}

/// Türkçe ve Azerbaycanca karakter duyarlılığını normalize eden arama yardımcısı.
public enum TurkicTextNormalizer {
    public static func normalize(_ input: String) -> String {
        let lower = input
            .replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "I", with: "ı")
            .lowercased()

        let replacements: [(String, String)] = [
            ("ə", "e"),
            ("ı", "i"),
            ("ş", "s"),
            ("ğ", "g"),
            ("ç", "c"),
            ("ö", "o"),
            ("ü", "u")
        ]

        var result = lower
        for (source, target) in replacements {
            result = result.replacingOccurrences(of: source, with: target)
        }
        return result.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
}

/// JSON dosyasına atomik yazım yapan kalıcı not deposu.
/// Uygulama kapanıp yeniden açıldığında aynı kimlik ve içerikle diskten yüklenir.
public final class FileBackedNoteStore: NoteStoreProtocol, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var notes: [PersistentNote] = []

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try reloadFromDisk()
    }

    public func createNote(content: String, sourceTaskId: UUID, now: Date) throws -> PersistentNote {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NoteStoreError.emptyContent
        }

        return try lock.withLock {
            let note = PersistentNote(
                id: UUID(),
                content: trimmed,
                createdAt: now,
                updatedAt: now,
                sourceTaskId: sourceTaskId,
                isDeleted: false
            )
            notes.append(note)
            try persistLocked()
            return note
        }
    }

    public func undoCreate(noteId: UUID, now: Date) throws -> PersistentNote {
        try lock.withLock {
            guard let index = notes.firstIndex(where: { $0.id == noteId && !$0.isDeleted }) else {
                throw NoteStoreError.noteNotFound(noteId)
            }
            notes[index].isDeleted = true
            notes[index].updatedAt = now
            let updated = notes[index]
            try persistLocked()
            return updated
        }
    }

    public func searchNotes(query: String) throws -> [PersistentNote] {
        let normalizedQuery = TurkicTextNormalizer.normalize(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return lock.withLock {
            let active = notes.filter { !$0.isDeleted }
            guard !normalizedQuery.isEmpty else {
                return active.sorted { $0.createdAt > $1.createdAt }
            }
            let tokens = normalizedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return active
                .filter { note in
                    let normalizedContent = TurkicTextNormalizer.normalize(note.content)
                    return tokens.allSatisfy { normalizedContent.contains($0) }
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func allActiveNotes() throws -> [PersistentNote] {
        lock.withLock {
            notes.filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func reloadFromDisk() throws {
        try lock.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else {
                notes = []
                return
            }
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                notes = []
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([PersistentNote].self, from: data)
        }
    }

    private func persistLocked() throws {
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(notes)
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }
}
