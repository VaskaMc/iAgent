import Foundation
import CryptoKit

// MARK: - Risk Sınıflandırması ve Biyometrik Doğrulama

/// Eylemlerin taşıdığı yan etki, gizlilik ve yetkilendirme risk katmanları.
public enum ActionRiskTier: Int, Codable, Comparable, CaseIterable, Sendable {
    /// Salt okuma veya yan etkisiz sorgular.
    case tier0ReadSafe = 0
    /// Geri alınabilir yerel yazmalar (not oluşturma vb.).
    case tier1LocalUndoable = 1
    /// Açık özet onayı gerektiren yerel yazmalar (takvim, anımsatıcı, alarm, hafıza kaydı).
    case tier2ExplicitConfirmation = 2
    /// Biyometrik doğrulama gerektiren yüksek riskli eylemler (dış iletişim, silme, finansal/kritik kestirme).
    case tier3BiometricRequired = 3

    public static func < (lhs: ActionRiskTier, rhs: ActionRiskTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static func classify(
        action: ActionKind,
        shortcutLabel: String? = nil,
        shortcutInput: String? = nil
    ) -> ActionRiskTier {
        switch action {
        case .notesSearch,
             .calendarRead,
             .remindersRead,
             .mapsDirections,
             .mapsEstimateETA,
             .assistantReply,
             .briefingCompose,
             .memoryRecall:
            return .tier0ReadSafe

        case .notesCreate,
             .textSummarizeAndNote:
            return .tier1LocalUndoable

        case .calendarCreate,
             .remindersCreate,
             .alarmCreate,
             .memoryRemember:
            return .tier2ExplicitConfirmation

        case .messagesCompose,
             .mailCompose,
             .shareSheet,
             .phoneCall,
             .memoryForget:
            return .tier3BiometricRequired

        case .shortcutsRun:
            let combinedRaw = [shortcutLabel ?? "", shortcutInput ?? ""].joined(separator: " ")
            let normalized = TurkicTextNormalizer.normalize(combinedRaw)
            let words = normalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }

            let substringTriggers = ["havale", "odeme", "banka", "kilit", "transfer", "para", "kocurme", "odenis"]
            if substringTriggers.contains(where: { normalized.contains($0) }) {
                return .tier3BiometricRequired
            }
            if words.contains(where: {
                $0 == "eft" || $0 == "sil" || $0.hasPrefix("silm") || $0.hasPrefix("silin") || $0 == "delete"
            }) {
                return .tier3BiometricRequired
            }
            return .tier2ExplicitConfirmation
        }
    }
}

/// Belirli bir `(taskId, revisionNumber, approvalDigest)` üçlüsüne HMAC-SHA256 ile bağlanmış biyometrik onay kanıtı.
public struct BiometricAttestation: Codable, Equatable, Sendable {
    public let id: UUID
    public let taskId: UUID
    public let revisionNumber: Int
    public let approvalDigest: String
    public let attestedAt: Date
    public let hmacHex: String

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String,
        attestedAt: Date,
        hmacHex: String
    ) {
        self.id = id
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.approvalDigest = approvalDigest
        self.attestedAt = attestedAt
        self.hmacHex = hmacHex
    }

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String,
        attestedAt: Date,
        signingKey: SymmetricKey
    ) {
        self.id = id
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.approvalDigest = approvalDigest
        self.attestedAt = attestedAt
        self.hmacHex = Self.computeHMACHex(
            id: id,
            taskId: taskId,
            revisionNumber: revisionNumber,
            approvalDigest: approvalDigest,
            attestedAt: attestedAt,
            using: signingKey
        )
    }

    public func verify(using key: SymmetricKey) -> Bool {
        guard let macData = AuditCryptoCoding.data(fromHex: hmacHex) else {
            return false
        }
        let message = Self.canonicalPayload(
            id: id,
            taskId: taskId,
            revisionNumber: revisionNumber,
            approvalDigest: approvalDigest,
            attestedAt: attestedAt
        )
        return HMAC<SHA256>.isValidAuthenticationCode(macData, authenticating: message, using: key)
    }

    public static func computeHMACHex(
        id: UUID,
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String,
        attestedAt: Date,
        using key: SymmetricKey
    ) -> String {
        let message = canonicalPayload(
            id: id,
            taskId: taskId,
            revisionNumber: revisionNumber,
            approvalDigest: approvalDigest,
            attestedAt: attestedAt
        )
        let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalPayload(
        id: UUID,
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String,
        attestedAt: Date
    ) -> Data {
        let epochSeconds = Int64(attestedAt.timeIntervalSince1970)
        var data = Data("iAgent.BiometricAttestation.v1\0".utf8)
        AuditCryptoCoding.appendString(id.uuidString, to: &data)
        AuditCryptoCoding.appendString(taskId.uuidString, to: &data)
        AuditCryptoCoding.appendInt64(Int64(revisionNumber), to: &data)
        AuditCryptoCoding.appendString(approvalDigest, to: &data)
        AuditCryptoCoding.appendInt64(epochSeconds, to: &data)
        return data
    }
}

public enum BiometricAuthError: Error, Equatable, Sendable {
    case cancelled
    case unavailable
    case failed(String)
}

public protocol BiometricAuthGateProtocol: Sendable {
    func authenticate(
        reason: String,
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String
    ) async throws -> BiometricAttestation
}

/// Testler ve simülatör ortamı için deterministik biyometrik doğrulama kapısı.
public final class MockBiometricAuthGate: BiometricAuthGateProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldSucceed: Bool
    private var errorToThrow: BiometricAuthError
    private let signingKey: SymmetricKey
    private let clock: ClockProtocol
    private var reasons: [String] = []

    public init(
        shouldSucceed: Bool = true,
        errorToThrow: BiometricAuthError = .cancelled,
        signingKey: SymmetricKey = SymmetricKey(size: .bits256),
        clock: ClockProtocol = SystemClock()
    ) {
        self.shouldSucceed = shouldSucceed
        self.errorToThrow = errorToThrow
        self.signingKey = signingKey
        self.clock = clock
    }

    public var key: SymmetricKey { signingKey }

    public func setShouldSucceed(_ value: Bool) {
        lock.withLock { shouldSucceed = value }
    }

    public func recordedReasons() -> [String] {
        lock.withLock { reasons }
    }

    public func authenticate(
        reason: String,
        taskId: UUID,
        revisionNumber: Int,
        approvalDigest: String
    ) async throws -> BiometricAttestation {
        let (ok, err, now) = lock.withLock { () -> (Bool, BiometricAuthError, Date) in
            reasons.append(reason)
            return (shouldSucceed, errorToThrow, clock.now())
        }
        guard ok else {
            throw err
        }
        return BiometricAttestation(
            taskId: taskId,
            revisionNumber: revisionNumber,
            approvalDigest: approvalDigest,
            attestedAt: now,
            signingKey: signingKey
        )
    }
}

// MARK: - Epistemik Dürüstlük ve Anayasal Yanıt Denetçisi (Claude Bilge)

/// Asistan yanıtlarındaki her iddianın kanıt derecesini sınıflandırır.
public enum EpistemicHonestyLevel: Codable, Equatable, Sendable {
    case evidenced(stepId: String, externalObjectId: String?)
    case handedOffToUser(target: String, stepId: String)
    case inferred(confidence: Double, basis: String)
    case uncertain(reason: String)
}

/// Doğrulanmış makbuz olmadan yan etki iddiası ("ekledim/kaydettim/gönderdim") üretilmesini engeller.
public enum JarvisConstitutionalGuard {
    private static let mutationClaimMarkers = [
        "ekledim", "kaydettim", "olusturdum", "kurdum", "sildim", "hatirlattim",
        "not aldim", "not ettim", "elave etdim", "saxladim", "yaratdim", "qurdum",
        "qeyd etdim", "xatirlatdim"
    ]

    private static let outboundSendClaimMarkers = [
        "gonderdim", "aradim", "zeng etdim", "paylasdim", "paylastim", "ilettim", "yolladim"
    ]

    public static func auditResponseClaims(
        candidateText: String,
        receipts: [ActionReceipt],
        language: AgentLanguage = .turkish
    ) -> (sanitizedText: String, rewritten: Bool, tags: [String: EpistemicHonestyLevel]) {
        var tags: [String: EpistemicHonestyLevel] = [:]
        for receipt in receipts {
            switch receipt.outcome {
            case .succeeded:
                tags[receipt.stepId] = .evidenced(
                    stepId: receipt.stepId,
                    externalObjectId: receipt.externalObjectId
                )
            case .handedOffToUserInterface:
                tags[receipt.stepId] = .handedOffToUser(
                    target: receipt.executorName,
                    stepId: receipt.stepId
                )
            case .uncertain, .failed, .cancelled:
                tags[receipt.stepId] = .uncertain(reason: receipt.detail)
            }
        }

        let normalized = TurkicTextNormalizer.normalize(candidateText)
        let claimsMutation = mutationClaimMarkers.contains { normalized.contains($0) }
        let claimsOutboundSend = outboundSendClaimMarkers.contains { normalized.contains($0) }

        let hasSucceededReceipt = receipts.contains { $0.outcome == .succeeded }
        let hasSucceededNonHandoffOutbound = receipts.contains {
            $0.outcome == .succeeded &&
            ($0.executorName.lowercased().contains("comm") || $0.executorName.lowercased().contains("mail") || $0.executorName.lowercased().contains("message"))
        }

        let unverifiedMutation = claimsMutation && !hasSucceededReceipt
        let unverifiedOutboundSend = claimsOutboundSend && !hasSucceededNonHandoffOutbound

        if unverifiedMutation || unverifiedOutboundSend {
            let reason = language == .azerbaijani
                ? "Təsdiqlənmiş icra qəbzi olmadan yan təsir iddiası bloklandı."
                : "Doğrulanmış başarı makbuzu olmadan yan etki iddiası engellendi."
            tags["claim_audit"] = .uncertain(reason: reason)

            let honestText: String
            if receipts.contains(where: { $0.outcome == .handedOffToUserInterface }) {
                honestText = language == .azerbaijani
                    ? "Əməliyyat sistem ekranına ötürüldü; hələ tamamlandığına və ya göndərildiyinə dair qəbz yoxdur."
                    : "İşlem sistem arayüzüne aktarıldı; gönderildiğine veya tamamlandığına dair henüz doğrulanmış makbuz bulunmuyor."
            } else {
                honestText = language == .azerbaijani
                    ? "Bu əməliyyat üçün təsdiqlənmiş icra qəbzi yoxdur; tamamlandığını təsdiq edə bilmirəm."
                    : "Bu işlem için doğrulanmış bir tamamlanma makbuzu bulunmuyor; işlemin tamamlandığını teyit edemiyorum."
            }
            return (sanitizedText: honestText, rewritten: true, tags: tags)
        }

        return (sanitizedText: candidateText, rewritten: false, tags: tags)
    }
}

// MARK: - Kriptografik Denetim İzi (Codex Bilge)

public struct AuditTrailEntry: Codable, Equatable, Identifiable, Sendable {
    public let sequenceIndex: Int
    public let id: UUID
    public let recordedAtEpochMicros: Int64
    public let receipt: ActionReceipt
    public let previousHashHex: String
    public let payloadHashHex: String
    public let entryHashHex: String
    public let hmacTagHex: String

    public init(
        sequenceIndex: Int,
        id: UUID,
        recordedAtEpochMicros: Int64,
        receipt: ActionReceipt,
        previousHashHex: String,
        payloadHashHex: String,
        entryHashHex: String,
        hmacTagHex: String
    ) {
        self.sequenceIndex = sequenceIndex
        self.id = id
        self.recordedAtEpochMicros = recordedAtEpochMicros
        self.receipt = receipt
        self.previousHashHex = previousHashHex
        self.payloadHashHex = payloadHashHex
        self.entryHashHex = entryHashHex
        self.hmacTagHex = hmacTagHex
    }
}

/// Her `ActionReceipt` kaydını önceki kaydın SHA-256 özeti ve HMAC-SHA256 ile zincirleyen denetim defteri.
/// Tek baytlık içerik değişikliği veya kuyruk kırpma girişimini `verifyIntegrity()` ile yakalar.
public final class CryptographicAuditTrail: @unchecked Sendable {
    private struct DiskEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let entryCount: Int
        let tailEntryHashHex: String
        let entries: [AuditTrailEntry]
        let envelopeHMACHex: String
    }

    private static let genesisHashHex = String(repeating: "0", count: 64)

    private let fileURL: URL?
    private let signingKey: SymmetricKey
    private let clock: ClockProtocol
    private let lock = NSLock()

    private var entries: [AuditTrailEntry] = []
    private var expectedCountAnchor: Int = 0
    private var expectedTailHashAnchor: String = CryptographicAuditTrail.genesisHashHex
    private var lastPersistedFileSHA256: String?
    private var lastPersistedByteCount: Int?
    private var diskIntegrityCompromised: Bool = false

    public init(
        fileURL: URL? = nil,
        hmacKeyData: Data? = nil,
        clock: ClockProtocol = SystemClock()
    ) throws {
        self.fileURL = fileURL
        if let hmacKeyData {
            self.signingKey = SymmetricKey(data: hmacKeyData)
        } else if let fileURL {
            let derived = SHA256.hash(data: Data("iAgent.AuditTrail.LocalKey|\(fileURL.standardizedFileURL.path)".utf8))
            self.signingKey = SymmetricKey(data: Data(derived))
        } else {
            self.signingKey = SymmetricKey(size: .bits256)
        }
        self.clock = clock

        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !data.isEmpty {
                do {
                    let decoder = Self.makeDecoder()
                    let envelope = try decoder.decode(DiskEnvelope.self, from: data)
                    self.entries = envelope.entries
                    self.expectedCountAnchor = envelope.entryCount
                    self.expectedTailHashAnchor = envelope.tailEntryHashHex
                    self.lastPersistedByteCount = data.count
                    self.lastPersistedFileSHA256 = Self.sha256Hex(data)

                    let expectedEnvelopeMAC = Self.computeEnvelopeHMACHex(
                        schemaVersion: envelope.schemaVersion,
                        entryCount: envelope.entryCount,
                        tailEntryHashHex: envelope.tailEntryHashHex,
                        entries: envelope.entries,
                        using: self.signingKey
                    )
                    if envelope.schemaVersion != 1
                        || envelope.entryCount != envelope.entries.count
                        || expectedEnvelopeMAC != envelope.envelopeHMACHex {
                        self.diskIntegrityCompromised = true
                    }
                } catch {
                    self.diskIntegrityCompromised = true
                }
            }
        }
    }

    @discardableResult
    public func record(receipt: ActionReceipt) throws -> AuditTrailEntry {
        try lock.withLock {
            let index = entries.count
            let entryId = UUID()
            let now = clock.now()
            let epochMicros = Int64((now.timeIntervalSince1970 * 1_000_000).rounded())
            let prevHash = entries.last?.entryHashHex ?? Self.genesisHashHex
            let payloadHash = Self.computePayloadHashHex(
                sequenceIndex: index,
                id: entryId,
                recordedAtEpochMicros: epochMicros,
                receipt: receipt
            )
            let entryHash = Self.computeEntryHashHex(
                previousHashHex: prevHash,
                payloadHashHex: payloadHash,
                sequenceIndex: index,
                id: entryId,
                recordedAtEpochMicros: epochMicros
            )
            let hmacTag = Self.computeEntryHMACHex(
                entryHashHex: entryHash,
                sequenceIndex: index,
                payloadHashHex: payloadHash,
                using: signingKey
            )

            let entry = AuditTrailEntry(
                sequenceIndex: index,
                id: entryId,
                recordedAtEpochMicros: epochMicros,
                receipt: receipt,
                previousHashHex: prevHash,
                payloadHashHex: payloadHash,
                entryHashHex: entryHash,
                hmacTagHex: hmacTag
            )

            entries.append(entry)
            expectedCountAnchor = entries.count
            expectedTailHashAnchor = entry.entryHashHex
            try persistLocked()
            return entry
        }
    }

    public func allEntries() -> [AuditTrailEntry] {
        lock.withLock { entries }
    }

    public func verifyIntegrity() -> Bool {
        lock.withLock {
            guard !diskIntegrityCompromised else { return false }

            guard Self.verifyChain(
                entries,
                expectedCount: expectedCountAnchor,
                expectedTailHashHex: expectedTailHashAnchor,
                using: signingKey
            ) else {
                return false
            }

            if let fileURL {
                let exists = FileManager.default.fileExists(atPath: fileURL.path)
                if entries.isEmpty && lastPersistedByteCount == nil {
                    return !exists || ((try? Data(contentsOf: fileURL).isEmpty) ?? false)
                }
                guard exists, let diskData = try? Data(contentsOf: fileURL) else {
                    return false
                }
                if let expectedBytes = lastPersistedByteCount, diskData.count != expectedBytes {
                    return false
                }
                if let expectedFileHash = lastPersistedFileSHA256, Self.sha256Hex(diskData) != expectedFileHash {
                    return false
                }

                guard let envelope = try? Self.makeDecoder().decode(DiskEnvelope.self, from: diskData) else {
                    return false
                }
                guard envelope.schemaVersion == 1,
                      envelope.entryCount == entries.count,
                      envelope.entries == entries,
                      envelope.tailEntryHashHex == (entries.last?.entryHashHex ?? Self.genesisHashHex) else {
                    return false
                }
                guard let envMacData = AuditCryptoCoding.data(fromHex: envelope.envelopeHMACHex) else {
                    return false
                }
                let envMessage = Self.envelopeMACMessage(
                    schemaVersion: envelope.schemaVersion,
                    entryCount: envelope.entryCount,
                    tailEntryHashHex: envelope.tailEntryHashHex,
                    entries: envelope.entries
                )
                guard HMAC<SHA256>.isValidAuthenticationCode(
                    envMacData,
                    authenticating: envMessage,
                    using: signingKey
                ) else {
                    return false
                }
            }

            return true
        }
    }

    public static func verifyChain(
        _ entries: [AuditTrailEntry],
        expectedCount: Int? = nil,
        expectedTailHashHex: String? = nil,
        using key: SymmetricKey
    ) -> Bool {
        if let expectedCount, entries.count != expectedCount {
            return false
        }
        let actualTail = entries.last?.entryHashHex ?? genesisHashHex
        if let expectedTailHashHex, actualTail != expectedTailHashHex {
            return false
        }

        var expectedPrev = genesisHashHex
        for (idx, entry) in entries.enumerated() {
            guard entry.sequenceIndex == idx,
                  entry.previousHashHex == expectedPrev else {
                return false
            }
            let recomputedPayload = computePayloadHashHex(
                sequenceIndex: entry.sequenceIndex,
                id: entry.id,
                recordedAtEpochMicros: entry.recordedAtEpochMicros,
                receipt: entry.receipt
            )
            guard recomputedPayload == entry.payloadHashHex else {
                return false
            }
            let recomputedEntryHash = computeEntryHashHex(
                previousHashHex: entry.previousHashHex,
                payloadHashHex: entry.payloadHashHex,
                sequenceIndex: entry.sequenceIndex,
                id: entry.id,
                recordedAtEpochMicros: entry.recordedAtEpochMicros
            )
            guard recomputedEntryHash == entry.entryHashHex else {
                return false
            }
            guard let macData = AuditCryptoCoding.data(fromHex: entry.hmacTagHex) else {
                return false
            }
            let macMsg = entryMACMessage(
                entryHashHex: entry.entryHashHex,
                sequenceIndex: entry.sequenceIndex,
                payloadHashHex: entry.payloadHashHex
            )
            guard HMAC<SHA256>.isValidAuthenticationCode(macData, authenticating: macMsg, using: key) else {
                return false
            }
            expectedPrev = entry.entryHashHex
        }
        return true
    }

    private func persistLocked() throws {
        guard let fileURL else { return }
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tailHash = entries.last?.entryHashHex ?? Self.genesisHashHex
        let envMAC = Self.computeEnvelopeHMACHex(
            schemaVersion: 1,
            entryCount: entries.count,
            tailEntryHashHex: tailHash,
            entries: entries,
            using: signingKey
        )
        let envelope = DiskEnvelope(
            schemaVersion: 1,
            entryCount: entries.count,
            tailEntryHashHex: tailHash,
            entries: entries,
            envelopeHMACHex: envMAC
        )
        let data = try Self.makeEncoder().encode(envelope)
        try data.write(to: fileURL, options: Self.secureWriteOptions)
        lastPersistedByteCount = data.count
        lastPersistedFileSHA256 = Self.sha256Hex(data)
    }

    private static var secureWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }

    private static func computePayloadHashHex(
        sequenceIndex: Int,
        id: UUID,
        recordedAtEpochMicros: Int64,
        receipt: ActionReceipt
    ) -> String {
        var data = Data("iAgent.AuditPayload.v1\0".utf8)
        AuditCryptoCoding.appendInt64(Int64(sequenceIndex), to: &data)
        AuditCryptoCoding.appendString(id.uuidString, to: &data)
        AuditCryptoCoding.appendInt64(recordedAtEpochMicros, to: &data)
        AuditCryptoCoding.appendString(receipt.id.uuidString, to: &data)
        AuditCryptoCoding.appendString(receipt.taskId.uuidString, to: &data)
        AuditCryptoCoding.appendInt64(Int64(receipt.revisionNumber), to: &data)
        AuditCryptoCoding.appendString(receipt.stepId, to: &data)
        AuditCryptoCoding.appendString(receipt.executorName, to: &data)
        AuditCryptoCoding.appendString(receipt.outcome.rawValue, to: &data)
        AuditCryptoCoding.appendOptionalString(receipt.externalObjectId, to: &data)
        // JSONDate coding (milisaniye çözünürlük) ile birebir uyumlu zaman temsili
        AuditCryptoCoding.appendInt64(Int64((receipt.timestamp.timeIntervalSince1970 * 1000).rounded()), to: &data)
        AuditCryptoCoding.appendBool(receipt.canUndo, to: &data)
        AuditCryptoCoding.appendString(receipt.spokenVerbTR, to: &data)
        AuditCryptoCoding.appendString(receipt.spokenVerbAZ, to: &data)
        AuditCryptoCoding.appendString(receipt.detail, to: &data)
        return sha256Hex(data)
    }

    private static func computeEntryHashHex(
        previousHashHex: String,
        payloadHashHex: String,
        sequenceIndex: Int,
        id: UUID,
        recordedAtEpochMicros: Int64
    ) -> String {
        var data = Data("iAgent.AuditEntry.v1\0".utf8)
        AuditCryptoCoding.appendString(previousHashHex, to: &data)
        AuditCryptoCoding.appendString(payloadHashHex, to: &data)
        AuditCryptoCoding.appendInt64(Int64(sequenceIndex), to: &data)
        AuditCryptoCoding.appendString(id.uuidString, to: &data)
        AuditCryptoCoding.appendInt64(recordedAtEpochMicros, to: &data)
        return sha256Hex(data)
    }

    private static func entryMACMessage(
        entryHashHex: String,
        sequenceIndex: Int,
        payloadHashHex: String
    ) -> Data {
        var data = Data("iAgent.AuditEntryMAC.v1\0".utf8)
        AuditCryptoCoding.appendString(entryHashHex, to: &data)
        AuditCryptoCoding.appendInt64(Int64(sequenceIndex), to: &data)
        AuditCryptoCoding.appendString(payloadHashHex, to: &data)
        return data
    }

    private static func computeEntryHMACHex(
        entryHashHex: String,
        sequenceIndex: Int,
        payloadHashHex: String,
        using key: SymmetricKey
    ) -> String {
        let msg = entryMACMessage(
            entryHashHex: entryHashHex,
            sequenceIndex: sequenceIndex,
            payloadHashHex: payloadHashHex
        )
        let code = HMAC<SHA256>.authenticationCode(for: msg, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func envelopeMACMessage(
        schemaVersion: Int,
        entryCount: Int,
        tailEntryHashHex: String,
        entries: [AuditTrailEntry]
    ) -> Data {
        var data = Data("iAgent.AuditEnvelopeMAC.v1\0".utf8)
        AuditCryptoCoding.appendInt64(Int64(schemaVersion), to: &data)
        AuditCryptoCoding.appendInt64(Int64(entryCount), to: &data)
        AuditCryptoCoding.appendString(tailEntryHashHex, to: &data)
        for entry in entries {
            AuditCryptoCoding.appendString(entry.entryHashHex, to: &data)
            AuditCryptoCoding.appendString(entry.hmacTagHex, to: &data)
        }
        return data
    }

    private static func computeEnvelopeHMACHex(
        schemaVersion: Int,
        entryCount: Int,
        tailEntryHashHex: String,
        entries: [AuditTrailEntry],
        using key: SymmetricKey
    ) -> String {
        let msg = envelopeMACMessage(
            schemaVersion: schemaVersion,
            entryCount: entryCount,
            tailEntryHashHex: tailEntryHashHex,
            entries: entries
        )
        let code = HMAC<SHA256>.authenticationCode(for: msg, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            let millis = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            try container.encode(millis)
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let millis = try container.decode(Int64.self)
            return Date(timeIntervalSince1970: Double(millis) / 1000.0)
        }
        return decoder
    }
}

private enum AuditCryptoCoding {
    static func appendString(_ value: String, to data: inout Data) {
        data.append(0x53)
        let utf8 = Data(value.utf8)
        var count = UInt64(utf8.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(utf8)
    }

    static func appendOptionalString(_ value: String?, to data: inout Data) {
        if let value {
            appendString(value, to: &data)
        } else {
            data.append(0x4E)
        }
    }

    static func appendInt64(_ value: Int64, to data: inout Data) {
        data.append(0x49)
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    static func appendBool(_ value: Bool, to data: inout Data) {
        data.append(0x42)
        data.append(value ? 0x01 : 0x00)
    }

    static func data(fromHex hex: String) -> Data? {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            result.append(byte)
            index = nextIndex
        }
        return result
    }
}

// MARK: - Prompt Enjeksiyonu Temizleyici

/// Paylaşılan belgeler, OCR metinleri ve harici girdilerdeki Unicode BiDi, zero-width, gizli HTML ve komut enjeksiyonlarını temizler.
public enum PromptInjectionSanitizer {
    public static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // 1. Unicode BiDi override/isolate, zero-width ve Tag blok karakterlerini ayıkla
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isBiDi = (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v)
                || v == 0x200E || v == 0x200F || v == 0x061C
            let isZeroWidth = v == 0x200B || v == 0x200C || v == 0x200D
                || v == 0xFEFF || v == 0x2060 || v == 0x00AD
            let isTagChar = (0xE0000...0xE007F).contains(v)
            if !isBiDi && !isZeroWidth && !isTagChar {
                scalars.append(scalar)
            }
        }
        var cleaned = String(scalars)

        // 2. <script>, <style>, HTML yorumları ve gizli HTML bloklarını sil
        let blockRemovalPatterns = [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?is)<!--.*?-->",
            "(?is)<([A-Za-z][A-Za-z0-9]*)\\b[^>]*style\\s*=\\s*[\"'][^\"']*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|opacity\\s*:\\s*0(?:\\.0+)?|font-size\\s*:\\s*0)[^\"']*[\"'][^>]*>.*?</\\1>",
            "(?is)<([A-Za-z][A-Za-z0-9]*)\\b[^>]*\\bhidden\\b[^>]*>.*?</\\1>",
            "</?[A-Za-z][A-Za-z0-9]*(?:\\s+[^>]*)?>"
        ]
        for _ in 0..<2 {
            for pattern in blockRemovalPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let range = NSRange(cleaned.startIndex..., in: cleaned)
                    cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: " ")
                }
            }
        }

        // 3. Yönerge enjeksiyonlarını (SİSTEM TALİMATI:, TƏLİMAT:, INSTRUCTION:, SYSTEM PROMPT:, IGNORE PREVIOUS ...) izole et
        let injectionLinePatterns = [
            "(?im)(?:^|[\\r\\n]|[\\.!?]\\s*)(?:S[İIıi]STEM\\s+)?(?:(?:YEN[İIıi]\\s+)?TAL[İIıi]MAT[Iıi]?|(?:YEN[İIıi]\\s+)?T[ƏEəe]L[İIıi]MAT[Iıi]?|Y[ÖOöo]NERGE|KOMUT|INSTRUCTIONS?|SYSTEM(?:\\s+PROMPT)?|DEVELOPER|ASSISTANT)\\s*:[^\\r\\n]*",
            "(?im)(?:^|[\\r\\n]|[\\.!?]\\s*)(?:IGNORE\\s+(?:ALL\\s+)?PREVIOUS\\s+INSTRUCTIONS|[ÖO]NCEK[İIıi]\\s+TAL[İIıi]MATLARI\\s+(?:YOK\\s+SAY|UNUT))[^\\r\\n]*"
        ]
        for pattern in injectionLinePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    options: [],
                    range: range,
                    withTemplate: " [IZOLE_EDILMIS_YONERGE]"
                )
            }
        }

        // Fazla boşlukları normalize et
        let collapsedLines = cleaned
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return collapsedLines.joined(separator: "\n")
    }
}
