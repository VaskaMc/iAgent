import Foundation

public enum AgentLanguage: String, Codable, Sendable, Equatable {
    case turkish = "tr"
    case azerbaijani = "az"
}

public enum QuickNoteIntent: Equatable, Sendable {
    case create(content: String)
    case search(query: String)
}

public struct PendingNoteDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskId: UUID
    public let content: String
    public let language: AgentLanguage
    public var isCancelled: Bool

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        content: String,
        language: AgentLanguage,
        isCancelled: Bool = false
    ) {
        self.id = id
        self.taskId = taskId
        self.content = content
        self.language = language
        self.isCancelled = isCancelled
    }
}

public enum QuickNoteOutcome: Equatable, Sendable {
    case noteCreated(note: PersistentNote, spokenSummary: String)
    case notesFound(query: String, matches: [PersistentNote], spokenSummary: String)
    case draftCancelled(spokenSummary: String)
    case needsContentClarification(spokenPrompt: String)
    case notMatched
}

/// Model bulunmadığında veya ilk uçtan uca akışta doğrudan çalışan sabit not akışı.
public struct QuickNoteFlow: Sendable {
    private let noteStore: NoteStoreProtocol

    public init(noteStore: NoteStoreProtocol) {
        self.noteStore = noteStore
    }

    /// Kullanıcının sözünü sabit not oluşturma veya not arama komutuna ayrıştırır.
    public func parseIntent(from utterance: String) -> QuickNoteIntent? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = TurkicTextNormalizer.normalize(trimmed)

        let searchMarkers = ["notunu bul", "notumu bul", "notlari bul", "qeydini tap", "qeydimi tap", "not ara"]
        if searchMarkers.contains(where: { normalized.contains($0) }) {
            let extracted = extractSearchTerms(from: trimmed)
            return .search(query: extracted)
        }

        let createPrefixes = [
            "sunu not al:",
            "sunu not al",
            "bunu not al:",
            "bunu not al",
            "not al:",
            "not al",
            "not ekle:",
            "not ekle",
            "bunu qeyd et:",
            "bunu qeyd et",
            "qeyd et:",
            "qeyd et"
        ]

        for prefix in createPrefixes {
            if normalized.hasPrefix(prefix) {
                let dropCount = prefix.count
                let content = String(trimmed.dropFirst(min(dropCount, trimmed.count)))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":,-\"“”")))
                return .create(content: content)
            }
        }

        return nil
    }

    /// Onay öncesi taslak oluşturur; kullanıcı vazgeçerse diske kayıt yazılmaz.
    public func prepareDraft(
        from utterance: String,
        taskId: UUID,
        language: AgentLanguage = .turkish
    ) -> PendingNoteDraft? {
        guard case .create(let content) = parseIntent(from: utterance), !content.isEmpty else {
            return nil
        }
        return PendingNoteDraft(taskId: taskId, content: content, language: language)
    }

    public func cancelPendingNote(_ draft: inout PendingNoteDraft) -> QuickNoteOutcome {
        draft.isCancelled = true
        let message = draft.language == .azerbaijani
            ? "Qeyd ləğv edildi, heç nə saxlanmadı."
            : "Not oluşturma iptal edildi, hiçbir kayıt eklenmedi."
        return .draftCancelled(spokenSummary: message)
    }

    public func confirmDraft(_ draft: PendingNoteDraft, now: Date) throws -> QuickNoteOutcome {
        guard !draft.isCancelled else {
            let message = draft.language == .azerbaijani
                ? "Ləğv edilmiş qaralama saxlanıla bilməz."
                : "Vazgeçilen not taslağı kaydedilemez."
            return .draftCancelled(spokenSummary: message)
        }
        let note = try noteStore.createNote(content: draft.content, sourceTaskId: draft.taskId, now: now)
        let message = draft.language == .azerbaijani
            ? "Qeyd saxlandı: \"\(note.content)\"."
            : "Not kaydedildi: \"\(note.content)\"."
        return .noteCreated(note: note, spokenSummary: message)
    }

    /// Tek adımlı açık "not al" isteğini yürütür (geri alınabilir yerel not).
    public func executeDirectIfMatched(
        utterance: String,
        taskId: UUID,
        now: Date,
        language: AgentLanguage = .turkish
    ) throws -> QuickNoteOutcome {
        guard let intent = parseIntent(from: utterance) else {
            return .notMatched
        }
        switch intent {
        case .create(let content):
            guard !content.isEmpty else {
                let prompt = language == .azerbaijani
                    ? "Nəyi qeyd etməyimi istəyirsən?"
                    : "Neyi not almamı istersin?"
                return .needsContentClarification(spokenPrompt: prompt)
            }
            let note = try noteStore.createNote(content: content, sourceTaskId: taskId, now: now)
            let summary = language == .azerbaijani
                ? "Qeyd saxlandı: \"\(note.content)\"."
                : "Not kaydedildi: \"\(note.content)\"."
            return .noteCreated(note: note, spokenSummary: summary)

        case .search(let query):
            let matches = try noteStore.searchNotes(query: query)
            let summary: String
            if matches.isEmpty {
                summary = language == .azerbaijani
                    ? "\"\(query)\" üçün qeyd tapılmadı."
                    : "\"\(query)\" ile eşleşen bir not bulunamadı."
            } else {
                summary = language == .azerbaijani
                    ? "\(matches.count) qeyd tapıldı."
                    : "\(matches.count) not bulundu: \"\(matches[0].content)\"."
            }
            return .notesFound(query: query, matches: matches, spokenSummary: summary)
        }
    }

    private func extractSearchTerms(from raw: String) -> String {
        let stopWords = Set([
            "dun", "bugun", "yazdigim", "yazdiqim", "notunu", "notumu", "notlari",
            "bul", "ara", "qeydini", "qeydimi", "tap", "not"
        ])
        let words = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let kept = words.filter { !stopWords.contains(TurkicTextNormalizer.normalize($0)) }
        return kept.joined(separator: " ")
    }
}
