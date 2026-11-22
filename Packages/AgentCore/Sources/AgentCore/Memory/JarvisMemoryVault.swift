import Foundation
import CryptoKit

// MARK: - Gizlilik ve Köken (Provenance) Modelleri

/// Kişisel hafıza kayıtlarının gizlilik ve dışa aktarılma sınırlarını tanımlar.
public enum MemoryPrivacyTier: String, Codable, CaseIterable, Equatable, Sendable {
    /// Yalnız bu iPhone üzerinde tutulur; asla bulut veya harici model sağlayıcılarına çıkmaz.
    case sensitivePersonal
    /// Varsayılan cihaz içi katman; yalnız açık kullanıcı izniyle özet bağlama alınabilir.
    case standardLocal
    /// Oturum / TTL sonunda temizlenen geçici bağlam kaydı.
    case ephemeralSession
}

/// Bir hafıza kaydı üzerinde yapılan her güncellemenin değiştirilemez düzenleme izi.
public struct ProvenanceEditRecord: Codable, Equatable, Sendable {
    public let editedAt: Date
    public let reason: String
    public let editorChannel: String

    public init(editedAt: Date, reason: String, editorChannel: String) {
        self.editedAt = editedAt
        self.reason = reason
        self.editorChannel = editorChannel
    }
}

/// Hafıza kaydının hangi kullanıcı sözünden, görevden ve kanaldan doğduğunu izler.
public struct MemoryProvenance: Codable, Equatable, Sendable {
    public let originId: UUID
    public let rawUtterance: String
    public let rawUtteranceSHA256: String
    public let sourceTaskId: UUID
    public let sourceChannel: String
    public let createdAt: Date
    public var editHistory: [ProvenanceEditRecord]

    public init(
        originId: UUID = UUID(),
        rawUtterance: String,
        rawUtteranceSHA256: String? = nil,
        sourceTaskId: UUID,
        sourceChannel: String,
        createdAt: Date,
        editHistory: [ProvenanceEditRecord] = []
    ) {
        self.originId = originId
        self.rawUtterance = rawUtterance
        self.rawUtteranceSHA256 = rawUtteranceSHA256 ?? Self.computeSHA256(rawUtterance)
        self.sourceTaskId = sourceTaskId
        self.sourceChannel = sourceChannel
        self.createdAt = createdAt
        self.editHistory = editHistory
    }

    public static func computeSHA256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Kişisel Hafıza Kasasında saklanan onaylı tercih/ilişki/alışkanlık kaydı.
public struct MemoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var key: String
    public var value: String
    public var tags: [String]
    public var privacyTier: MemoryPrivacyTier
    public var provenance: MemoryProvenance
    public var isActive: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        value: String,
        tags: [String] = [],
        privacyTier: MemoryPrivacyTier = .standardLocal,
        provenance: MemoryProvenance,
        isActive: Bool = true,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.tags = tags
        self.privacyTier = privacyTier
        self.provenance = provenance
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

// MARK: - Sır ve Hassas Veri Muhafızı

/// Parola, PIN, API anahtarı, JWT, IBAN, TCKN ve kart numaralarının düz metin hafızaya yazılmasını engeller.
public enum MemorySecretGuard {
    private static var secretPatterns: [String] {
        let skPrefix = "sk" + "-"
        let skProj = "sk" + "_proj-"
        return [
            "(?:\\b\(skPrefix)|\\b\(skProj)|\\bghp_|\\bAIza|\\bxox[baprs]-|\\bAKIA)[A-Za-z0-9_\\-]{12,}\\b",
            "(?i)\\bBearer\\s+[A-Za-z0-9\\-._~+/]+=*",
            "\\beyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}(?:\\.[A-Za-z0-9_\\-]{4,})?\\b",
            "(?i)\\bTR(?:\\s*\\d){24}\\b",
            "(?i)\\bAZ\\d{2}(?:\\s*[A-Za-z0-9]){24}\\b",
            "(?i)\\b(?:tckn|tc\\s*kimlik(?:\\s*no)?|kimlik\\s*no)\\s*[:=\\-]?\\s*[1-9]\\d{10}\\b",
            "(?<![+\\d])\\b[1-9]\\d{10}\\b",
            "\\b(?:\\d{4}[-\\s]?){3}\\d{4}\\b",
            "(?i)\\b(?:parola[mr]?|[sşSŞ][iİıI]fr[eəEƏ][mrMR]?|password|passcode|pin(?:\\s*kodu[mn]?)?|api[\\s_\\-]?key|gizli\\s*anahtar)\\b\\s*[:=\\-]?\\s*\\S+"
        ]
    }

    public static func containsSensitiveSecret(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let fullRange = NSRange(text.startIndex..., in: text)
        for pattern in secretPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, options: [], range: fullRange) != nil {
                return true
            }
        }
        return false
    }

    public static func redactSecrets(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var redacted = text
        for pattern in secretPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(redacted.startIndex..., in: redacted)
                redacted = regex.stringByReplacingMatches(
                    in: redacted,
                    options: [],
                    range: range,
                    withTemplate: "[REDACTED]"
                )
            }
        }
        return redacted
    }
}

// MARK: - Alışkanlık Gözlem Adayı

/// En az 3 farklı görevde gözlemlenen örüntüler için kullanıcı onaylı hafıza önerisi üretir.
public struct HabitObservationCandidate: Codable, Equatable, Sendable {
    public let canonicalPatternKey: String
    public let proposedStatementTR: String
    public let proposedStatementAZ: String
    public let observationCount: Int
    public let distinctTaskIds: [UUID]
    public let suggestedPrivacyTier: MemoryPrivacyTier
    public let requiresUserConfirmation: Bool

    public init(
        canonicalPatternKey: String,
        proposedStatementTR: String,
        proposedStatementAZ: String,
        observationCount: Int,
        distinctTaskIds: [UUID],
        suggestedPrivacyTier: MemoryPrivacyTier = .standardLocal,
        requiresUserConfirmation: Bool = true
    ) {
        self.canonicalPatternKey = canonicalPatternKey
        self.proposedStatementTR = proposedStatementTR
        self.proposedStatementAZ = proposedStatementAZ
        self.observationCount = observationCount
        self.distinctTaskIds = distinctTaskIds
        self.suggestedPrivacyTier = suggestedPrivacyTier
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}

/// Tekrarlayan örüntüleri izler ve ancak `>= 3` farklı görevde gözlemlendiğinde onay adayı üretir.
public final class HabitObservationTracker: @unchecked Sendable {
    public static let minimumDistinctTaskThreshold = 3

    private struct Bucket: Codable, Sendable {
        var canonicalPatternKey: String
        var statementTR: String
        var statementAZ: String
        var observationCount: Int
        var distinctTaskIds: [UUID]
        var suggestedPrivacyTier: MemoryPrivacyTier
    }

    private let lock = NSLock()
    private var buckets: [String: Bucket] = [:]

    public init() {}

    public func observe(
        patternKey: String,
        statementTR: String,
        statementAZ: String,
        taskId: UUID,
        suggestedPrivacyTier: MemoryPrivacyTier = .standardLocal
    ) -> HabitObservationCandidate? {
        let normalizedKey = TurkicTextNormalizer.normalize(
            patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalizedKey.isEmpty,
              !MemorySecretGuard.containsSensitiveSecret(statementTR),
              !MemorySecretGuard.containsSensitiveSecret(statementAZ) else {
            return nil
        }

        return lock.withLock {
            var bucket = buckets[normalizedKey] ?? Bucket(
                canonicalPatternKey: normalizedKey,
                statementTR: statementTR,
                statementAZ: statementAZ,
                observationCount: 0,
                distinctTaskIds: [],
                suggestedPrivacyTier: suggestedPrivacyTier
            )
            bucket.observationCount += 1
            if !bucket.distinctTaskIds.contains(taskId) {
                bucket.distinctTaskIds.append(taskId)
            }
            bucket.statementTR = statementTR
            bucket.statementAZ = statementAZ
            bucket.suggestedPrivacyTier = suggestedPrivacyTier
            buckets[normalizedKey] = bucket

            guard bucket.distinctTaskIds.count >= Self.minimumDistinctTaskThreshold else {
                return nil
            }
            return HabitObservationCandidate(
                canonicalPatternKey: bucket.canonicalPatternKey,
                proposedStatementTR: bucket.statementTR,
                proposedStatementAZ: bucket.statementAZ,
                observationCount: bucket.observationCount,
                distinctTaskIds: bucket.distinctTaskIds,
                suggestedPrivacyTier: bucket.suggestedPrivacyTier,
                requiresUserConfirmation: true
            )
        }
    }

    public func candidate(forPatternKey patternKey: String) -> HabitObservationCandidate? {
        let normalizedKey = TurkicTextNormalizer.normalize(
            patternKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return lock.withLock {
            guard let bucket = buckets[normalizedKey],
                  bucket.distinctTaskIds.count >= Self.minimumDistinctTaskThreshold else {
                return nil
            }
            return HabitObservationCandidate(
                canonicalPatternKey: bucket.canonicalPatternKey,
                proposedStatementTR: bucket.statementTR,
                proposedStatementAZ: bucket.statementAZ,
                observationCount: bucket.observationCount,
                distinctTaskIds: bucket.distinctTaskIds,
                suggestedPrivacyTier: bucket.suggestedPrivacyTier,
                requiresUserConfirmation: true
            )
        }
    }
}

// MARK: - Dosya Tabanlı Kişisel Hafıza Kasası

public enum MemoryVaultError: Error, Equatable, Sendable {
    case emptyKeyOrValue
    case sensitiveSecretRejected
    case entryNotFound(UUID)
}

/// CloudKit-kapalı, cihaz içi tam dosya korumalı kişisel hafıza kasası.
/// Görev geçmişi temizlense dahi yaşam döngüsü bağımsızdır.
public final class FileBackedMemoryVault: @unchecked Sendable {
    private struct VaultDiskPayload: Codable, Sendable {
        let schemaVersion: Int
        let entries: [MemoryEntry]
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [MemoryEntry] = []
    private let habitTracker = HabitObservationTracker()

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        if fileURL != nil {
            try reloadFromDisk()
        }
    }

    @discardableResult
    public func remember(
        key: String,
        value: String,
        tags: [String] = [],
        privacyTier: MemoryPrivacyTier = .standardLocal,
        provenance: MemoryProvenance,
        now: Date = Date()
    ) throws -> MemoryEntry {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanValue.isEmpty else {
            throw MemoryVaultError.emptyKeyOrValue
        }
        guard !MemorySecretGuard.containsSensitiveSecret(cleanKey),
              !MemorySecretGuard.containsSensitiveSecret(cleanValue),
              !MemorySecretGuard.containsSensitiveSecret(provenance.rawUtterance) else {
            throw MemoryVaultError.sensitiveSecretRejected
        }

        let cleanTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !MemorySecretGuard.containsSensitiveSecret($0) }

        return try lock.withLock {
            let entry = MemoryEntry(
                id: UUID(),
                key: cleanKey,
                value: cleanValue,
                tags: cleanTags,
                privacyTier: privacyTier,
                provenance: provenance,
                isActive: true,
                createdAt: now,
                updatedAt: now
            )
            entries.append(entry)
            try persistLocked()
            return entry
        }
    }

    @discardableResult
    public func remember(
        key: String,
        value: String,
        tags: [String] = [],
        privacyTier: MemoryPrivacyTier = .standardLocal,
        rawUtterance: String,
        sourceTaskId: UUID,
        sourceChannel: String = "inAppText",
        now: Date = Date()
    ) throws -> MemoryEntry {
        let provenance = MemoryProvenance(
            rawUtterance: rawUtterance,
            sourceTaskId: sourceTaskId,
            sourceChannel: sourceChannel,
            createdAt: now
        )
        return try remember(
            key: key,
            value: value,
            tags: tags,
            privacyTier: privacyTier,
            provenance: provenance,
            now: now
        )
    }

    @discardableResult
    public func update(
        id: UUID,
        newValue: String,
        reason: String,
        editorChannel: String = "inAppText",
        now: Date = Date()
    ) throws -> MemoryEntry {
        let cleanValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanValue.isEmpty else {
            throw MemoryVaultError.emptyKeyOrValue
        }
        guard !MemorySecretGuard.containsSensitiveSecret(cleanValue) else {
            throw MemoryVaultError.sensitiveSecretRejected
        }

        return try lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == id && $0.isActive }) else {
                throw MemoryVaultError.entryNotFound(id)
            }
            entries[index].value = cleanValue
            entries[index].updatedAt = now
            entries[index].provenance.editHistory.append(
                ProvenanceEditRecord(editedAt: now, reason: reason, editorChannel: editorChannel)
            )
            let updated = entries[index]
            try persistLocked()
            return updated
        }
    }

    public func recall(
        query: String,
        limit: Int = 10,
        includeSensitivePersonal: Bool = true
    ) -> [MemoryEntry] {
        guard limit > 0 else { return [] }
        let normalizedQuery = TurkicTextNormalizer.normalize(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let tokens = normalizedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        return lock.withLock {
            let candidates = entries.filter { entry in
                entry.isActive && (includeSensitivePersonal || entry.privacyTier != .sensitivePersonal)
            }
            if tokens.isEmpty {
                return Array(candidates.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
            }

            let scored: [(entry: MemoryEntry, score: Int)] = candidates.compactMap { entry in
                let normKey = TurkicTextNormalizer.normalize(entry.key)
                let normValue = TurkicTextNormalizer.normalize(entry.value)
                let normTags = entry.tags.map { TurkicTextNormalizer.normalize($0) }.joined(separator: " ")
                let haystack = "\(normKey) \(normValue) \(normTags)"

                var matchCount = 0
                var weightedScore = 0
                for token in tokens {
                    var matched = false
                    if normKey.contains(token) {
                        weightedScore += 4
                        matched = true
                    }
                    if normValue.contains(token) {
                        weightedScore += 3
                        matched = true
                    }
                    if normTags.contains(token) {
                        weightedScore += 2
                        matched = true
                    }
                    if matched {
                        matchCount += 1
                    } else if haystack.contains(token) {
                        weightedScore += 1
                        matchCount += 1
                    }
                }
                guard matchCount > 0 else { return nil }
                if matchCount == tokens.count {
                    weightedScore += 5
                }
                if normKey == normalizedQuery || normValue == normalizedQuery {
                    weightedScore += 10
                }
                return (entry, weightedScore)
            }

            return Array(
                scored
                    .sorted {
                        if $0.score != $1.score {
                            return $0.score > $1.score
                        }
                        return $0.entry.updatedAt > $1.entry.updatedAt
                    }
                    .map(\.entry)
                    .prefix(limit)
            )
        }
    }

    @discardableResult
    public func forget(id: UUID, now: Date = Date()) throws -> MemoryEntry {
        try lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == id && $0.isActive }) else {
                throw MemoryVaultError.entryNotFound(id)
            }
            entries[index].isActive = false
            entries[index].updatedAt = now
            entries[index].provenance.editHistory.append(
                ProvenanceEditRecord(editedAt: now, reason: "forget", editorChannel: "vault")
            )
            let updated = entries[index]
            try persistLocked()
            return updated
        }
    }

    @discardableResult
    public func undoForget(id: UUID, now: Date = Date()) throws -> MemoryEntry {
        try lock.withLock {
            guard let index = entries.firstIndex(where: { $0.id == id && !$0.isActive }) else {
                throw MemoryVaultError.entryNotFound(id)
            }
            entries[index].isActive = true
            entries[index].updatedAt = now
            entries[index].provenance.editHistory.append(
                ProvenanceEditRecord(editedAt: now, reason: "undoForget", editorChannel: "vault")
            )
            let updated = entries[index]
            try persistLocked()
            return updated
        }
    }

    public func activeEntries() -> [MemoryEntry] {
        lock.withLock {
            entries.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func observe(
        patternKey: String,
        statementTR: String,
        statementAZ: String,
        taskId: UUID,
        suggestedPrivacyTier: MemoryPrivacyTier = .standardLocal
    ) -> HabitObservationCandidate? {
        habitTracker.observe(
            patternKey: patternKey,
            statementTR: statementTR,
            statementAZ: statementAZ,
            taskId: taskId,
            suggestedPrivacyTier: suggestedPrivacyTier
        )
    }

    public func purgeEphemeralEntries(olderThan cutoff: Date) throws {
        try lock.withLock {
            let before = entries.count
            entries.removeAll { $0.privacyTier == .ephemeralSession && $0.updatedAt < cutoff }
            if entries.count != before {
                try persistLocked()
            }
        }
    }

    public func reloadFromDisk() throws {
        try lock.withLock {
            guard let fileURL else { return }
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else {
                entries = []
                return
            }
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                entries = []
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let envelope = try? decoder.decode(VaultDiskPayload.self, from: data) {
                entries = envelope.entries
            } else {
                entries = try decoder.decode([MemoryEntry].self, from: data)
            }
        }
    }

    private func persistLocked() throws {
        guard let fileURL else { return }
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = VaultDiskPayload(schemaVersion: 1, entries: entries)
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: Self.secureWriteOptions)
    }

    private static var secureWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
}

// MARK: - Bağlam Sıkıştırma ve 4.096 Token Bütçesi (Claude Bilge)

/// Cihaz içi Apple Foundation Models 4.096-token bağlam penceresi için bütçe yapılandırması.
public struct CompactionBudgetConfig: Codable, Equatable, Sendable {
    public let maxContextTokens: Int
    public let reservedSystemTokens: Int
    public let reservedResponseTokens: Int
    public let turkicExpansionMargin: Double

    public init(
        maxContextTokens: Int = 4096,
        reservedSystemTokens: Int = 512,
        reservedResponseTokens: Int = 768,
        turkicExpansionMargin: Double = 0.15
    ) {
        self.maxContextTokens = maxContextTokens
        self.reservedSystemTokens = reservedSystemTokens
        self.reservedResponseTokens = reservedResponseTokens
        self.turkicExpansionMargin = turkicExpansionMargin
    }

    public var availableInputBudgetTokens: Int {
        max(128, maxContextTokens - reservedResponseTokens)
    }

    public static let ios26OnDevice4096 = CompactionBudgetConfig(
        maxContextTokens: 4096,
        reservedSystemTokens: 512,
        reservedResponseTokens: 768,
        turkicExpansionMargin: 0.15
    )
}

/// Türkçe ve Azerbaycanca sondan eklemeli BPE genişlemesi için %15 güvenlik marjlı token tahmincisi.
public enum TurkicHeuristicTokenEstimator {
    public static func estimateTokens(for text: String, safetyMargin: Double = 0.15) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let charCount = Double(trimmed.count)
        let wordCount = Double(trimmed.split(whereSeparator: { $0.isWhitespace }).count)
        // Eklemeli Türk dilleri BPE'de ~2.7 karakter/token veya ~1.6 token/kelime harcar
        let baseEstimate = max(charCount / 2.7, wordCount * 1.6)
        return max(1, Int(ceil(baseEstimate * (1.0 + max(0.0, safetyMargin)))))
    }

    public static func truncate(_ text: String, toMaxTokens maxTokens: Int, safetyMargin: Double = 0.15) -> String {
        guard maxTokens > 0 else { return "" }
        if estimateTokens(for: text, safetyMargin: safetyMargin) <= maxTokens {
            return text
        }
        let maxChars = max(1, Int(floor((Double(maxTokens) / (1.0 + max(0.0, safetyMargin))) * 2.5)))
        if text.count <= maxChars {
            return text
        }
        let prefixText = String(text.prefix(max(1, maxChars - 3)))
        let result = prefixText + "..."
        if estimateTokens(for: result, safetyMargin: safetyMargin) <= maxTokens {
            return result
        }
        return String(text.prefix(max(1, maxChars / 2)))
    }
}

public enum TurnRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case system
    case tool
}

public struct TurnRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskId: UUID
    public let role: TurnRole
    public let text: String
    public let timestamp: Date
    public let sourceChannel: String
    public let containsActionReceipt: Bool

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        role: TurnRole,
        text: String,
        timestamp: Date,
        sourceChannel: String = "inAppText",
        containsActionReceipt: Bool = false
    ) {
        self.id = id
        self.taskId = taskId
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.sourceChannel = sourceChannel
        self.containsActionReceipt = containsActionReceipt
    }
}

public struct ApprovedMemorySnippet: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let memoryId: UUID
    public let key: String
    public let value: String
    public let privacyTier: MemoryPrivacyTier
    public let provenance: MemoryProvenance

    public init(
        id: UUID = UUID(),
        memoryId: UUID,
        key: String,
        value: String,
        privacyTier: MemoryPrivacyTier,
        provenance: MemoryProvenance
    ) {
        self.id = id
        self.memoryId = memoryId
        self.key = key
        self.value = value
        self.privacyTier = privacyTier
        self.provenance = provenance
    }

    public init(entry: MemoryEntry) {
        self.id = UUID()
        self.memoryId = entry.id
        self.key = entry.key
        self.value = entry.value
        self.privacyTier = entry.privacyTier
        self.provenance = entry.provenance
    }
}

public struct CompactedEpisode: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let summary: String
    public let sourceTaskIds: [UUID]
    public let provenanceOrigins: [UUID]
    public let turnCount: Int
    public let estimatedTokens: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        summary: String,
        sourceTaskIds: [UUID],
        provenanceOrigins: [UUID] = [],
        turnCount: Int,
        estimatedTokens: Int,
        createdAt: Date
    ) {
        self.id = id
        self.summary = summary
        self.sourceTaskIds = sourceTaskIds
        self.provenanceOrigins = provenanceOrigins
        self.turnCount = turnCount
        self.estimatedTokens = estimatedTokens
        self.createdAt = createdAt
    }
}

public struct MemoryCandidateProposal: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let candidate: HabitObservationCandidate
    public let requiresExplicitUserApproval: Bool

    public init(
        id: UUID = UUID(),
        candidate: HabitObservationCandidate,
        requiresExplicitUserApproval: Bool = true
    ) {
        self.id = id
        self.candidate = candidate
        self.requiresExplicitUserApproval = requiresExplicitUserApproval
    }
}

public struct CompactedPromptPayload: Codable, Equatable, Sendable {
    public let systemInstruction: String
    public let approvedMemories: [ApprovedMemorySnippet]
    public let compactedEpisodes: [CompactedEpisode]
    public let recentTurns: [TurnRecord]
    public let estimatedTotalTokens: Int
    public let budgetConfig: CompactionBudgetConfig

    public init(
        systemInstruction: String,
        approvedMemories: [ApprovedMemorySnippet],
        compactedEpisodes: [CompactedEpisode],
        recentTurns: [TurnRecord],
        estimatedTotalTokens: Int,
        budgetConfig: CompactionBudgetConfig
    ) {
        self.systemInstruction = systemInstruction
        self.approvedMemories = approvedMemories
        self.compactedEpisodes = compactedEpisodes
        self.recentTurns = recentTurns
        self.estimatedTotalTokens = estimatedTotalTokens
        self.budgetConfig = budgetConfig
    }
}

public struct CompactionResult: Codable, Equatable, Sendable {
    public let payload: CompactedPromptPayload
    public let droppedTurnCount: Int
    public let candidateProposals: [MemoryCandidateProposal]
    public let withinBudget: Bool

    public init(
        payload: CompactedPromptPayload,
        droppedTurnCount: Int,
        candidateProposals: [MemoryCandidateProposal],
        withinBudget: Bool
    ) {
        self.payload = payload
        self.droppedTurnCount = droppedTurnCount
        self.candidateProposals = candidateProposals
        self.withinBudget = withinBudget
    }
}

/// Cihaz içi 4.096-token bağlam penceresi için köken-korumalı epizodik sıkıştırma aktörü.
public actor JarvisContextCompactor {
    private let budgetConfig: CompactionBudgetConfig

    public init(budgetConfig: CompactionBudgetConfig = .ios26OnDevice4096) {
        self.budgetConfig = budgetConfig
    }

    public func compact(
        systemInstruction: String,
        turns: [TurnRecord],
        approvedMemories: [ApprovedMemorySnippet],
        existingEpisodes: [CompactedEpisode] = [],
        habitCandidates: [HabitObservationCandidate] = [],
        destinationIsCloud: Bool = false,
        now: Date = Date()
    ) -> CompactionResult {
        let margin = budgetConfig.turkicExpansionMargin
        let totalBudget = min(budgetConfig.availableInputBudgetTokens, budgetConfig.maxContextTokens)

        let boundedSystem = TurkicHeuristicTokenEstimator.truncate(
            MemorySecretGuard.redactSecrets(in: systemInstruction),
            toMaxTokens: min(budgetConfig.reservedSystemTokens, totalBudget / 2),
            safetyMargin: margin
        )
        var usedTokens = TurkicHeuristicTokenEstimator.estimateTokens(for: boundedSystem, safetyMargin: margin)

        // 1. Onaylı hafıza parçalarını gizlilik sınırına göre süz
        let memoryBudgetCap = max(0, (totalBudget - usedTokens) / 3)
        var selectedMemories: [ApprovedMemorySnippet] = []
        var memoryTokensUsed = 0

        for snippet in approvedMemories {
            if destinationIsCloud && snippet.privacyTier == .sensitivePersonal {
                continue
            }
            if MemorySecretGuard.containsSensitiveSecret(snippet.key)
                || MemorySecretGuard.containsSensitiveSecret(snippet.value) {
                continue
            }
            let rendered = "\(snippet.key): \(snippet.value)"
            let cost = TurkicHeuristicTokenEstimator.estimateTokens(for: rendered, safetyMargin: margin) + 4
            if memoryTokensUsed + cost <= memoryBudgetCap && usedTokens + memoryTokensUsed + cost <= totalBudget {
                selectedMemories.append(snippet)
                memoryTokensUsed += cost
            }
        }
        usedTokens += memoryTokensUsed

        // 2. En yeni turlara öncelik ver, eski turları sıkıştırılmış epizoda düşür
        let chronologicalTurns = turns.sorted { $0.timestamp < $1.timestamp }
        var keptTurnsReversed: [TurnRecord] = []
        var droppedTurns: [TurnRecord] = []

        let reserveForEpisode = chronologicalTurns.count > 1 ? min(280, max(64, (totalBudget - usedTokens) / 4)) : 0
        let turnBudget = max(0, totalBudget - usedTokens - reserveForEpisode)
        var turnTokensUsed = 0

        for turn in chronologicalTurns.reversed() {
            let safeText = MemorySecretGuard.redactSecrets(in: turn.text)
            let sanitizedTurn = TurnRecord(
                id: turn.id,
                taskId: turn.taskId,
                role: turn.role,
                text: safeText,
                timestamp: turn.timestamp,
                sourceChannel: turn.sourceChannel,
                containsActionReceipt: turn.containsActionReceipt
            )
            let cost = TurkicHeuristicTokenEstimator.estimateTokens(for: "\(turn.role.rawValue): \(safeText)", safetyMargin: margin) + 3
            if turnTokensUsed + cost <= turnBudget {
                keptTurnsReversed.append(sanitizedTurn)
                turnTokensUsed += cost
            } else {
                droppedTurns.append(sanitizedTurn)
            }
        }

        let recentTurns = Array(keptTurnsReversed.reversed())
        droppedTurns.reverse()
        usedTokens += turnTokensUsed

        // 3. Düşen turları ve mevcut epizodları kalan bütçeye sığdır
        var finalEpisodes: [CompactedEpisode] = []
        var remainingForEpisodes = max(0, totalBudget - usedTokens)

        if !droppedTurns.isEmpty && remainingForEpisodes >= 16 {
            let snippets = droppedTurns.map { "[\($0.role.rawValue)] \(String($0.text.prefix(80)))" }
            let rawSummary = "Önceki \(droppedTurns.count) tur özeti: " + snippets.joined(separator: " | ")
            let truncatedSummary = TurkicHeuristicTokenEstimator.truncate(
                rawSummary,
                toMaxTokens: remainingForEpisodes,
                safetyMargin: margin
            )
            let epTokens = TurkicHeuristicTokenEstimator.estimateTokens(for: truncatedSummary, safetyMargin: margin)
            if epTokens <= remainingForEpisodes {
                let uniqueTaskIds = droppedTurns.reduce(into: [UUID]()) { acc, t in
                    if !acc.contains(t.taskId) { acc.append(t.taskId) }
                }
                let originIds = selectedMemories.map(\.provenance.originId)
                let newEpisode = CompactedEpisode(
                    summary: truncatedSummary,
                    sourceTaskIds: uniqueTaskIds,
                    provenanceOrigins: originIds,
                    turnCount: droppedTurns.count,
                    estimatedTokens: epTokens,
                    createdAt: now
                )
                finalEpisodes.append(newEpisode)
                usedTokens += epTokens
                remainingForEpisodes -= epTokens
            }
        }

        for episode in existingEpisodes.reversed() where remainingForEpisodes >= 16 {
            let safeSummary = TurkicHeuristicTokenEstimator.truncate(
                MemorySecretGuard.redactSecrets(in: episode.summary),
                toMaxTokens: remainingForEpisodes,
                safetyMargin: margin
            )
            let tokens = TurkicHeuristicTokenEstimator.estimateTokens(for: safeSummary, safetyMargin: margin)
            if tokens > 0 && tokens <= remainingForEpisodes {
                finalEpisodes.insert(
                    CompactedEpisode(
                        id: episode.id,
                        summary: safeSummary,
                        sourceTaskIds: episode.sourceTaskIds,
                        provenanceOrigins: episode.provenanceOrigins,
                        turnCount: episode.turnCount,
                        estimatedTokens: tokens,
                        createdAt: episode.createdAt
                    ),
                    at: 0
                )
                usedTokens += tokens
                remainingForEpisodes -= tokens
            }
        }

        // 4. >= 3 farklı görevde gözlemlenen alışkanlıkları onay adayı olarak sun
        let proposals = habitCandidates
            .filter { $0.distinctTaskIds.count >= HabitObservationTracker.minimumDistinctTaskThreshold && $0.requiresUserConfirmation }
            .map { MemoryCandidateProposal(candidate: $0, requiresExplicitUserApproval: true) }

        let payload = CompactedPromptPayload(
            systemInstruction: boundedSystem,
            approvedMemories: selectedMemories,
            compactedEpisodes: finalEpisodes,
            recentTurns: recentTurns,
            estimatedTotalTokens: usedTokens,
            budgetConfig: budgetConfig
        )

        return CompactionResult(
            payload: payload,
            droppedTurnCount: droppedTurns.count,
            candidateProposals: proposals,
            withinBudget: usedTokens <= budgetConfig.maxContextTokens
        )
    }
}
