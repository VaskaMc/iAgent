import Foundation

public struct JournalEntry: Codable, Equatable, Sendable {
    public let taskId: UUID
    public let revisionNumber: Int
    public let stepId: String
    public let action: ActionKind
    public let titleOrTarget: String
    public let startedAt: Date
    public var receipt: ActionReceipt?

    public init(
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        action: ActionKind,
        titleOrTarget: String,
        startedAt: Date,
        receipt: ActionReceipt? = nil
    ) {
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.stepId = stepId
        self.action = action
        self.titleOrTarget = titleOrTarget
        self.startedAt = startedAt
        self.receipt = receipt
    }
}

/// Süreç çökmesi veya ani kapanma durumları için yazma öncesi günlük.
public final class WriteAheadJournal: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [JournalEntry] = []

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if !data.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.entries = try decoder.decode([JournalEntry].self, from: data)
            }
        }
    }

    public func beginStep(taskId: UUID, revisionNumber: Int, step: ActionStep, now: Date) {
        let label = step.parameters.title ?? step.parameters.noteContent ?? step.parameters.shortcutLabel ?? step.action.rawValue
        lock.withLock {
            entries.append(
                JournalEntry(
                    taskId: taskId,
                    revisionNumber: revisionNumber,
                    stepId: step.id,
                    action: step.action,
                    titleOrTarget: label,
                    startedAt: now,
                    receipt: nil
                )
            )
            persistLocked()
        }
    }

    public func completeStep(taskId: UUID, revisionNumber: Int, stepId: String, receipt: ActionReceipt) {
        lock.withLock {
            if let idx = entries.lastIndex(where: {
                $0.taskId == taskId && $0.revisionNumber == revisionNumber && $0.stepId == stepId && $0.receipt == nil
            }) {
                entries[idx].receipt = receipt
                persistLocked()
            }
        }
    }

    public func unresolvedEntries() -> [JournalEntry] {
        lock.withLock {
            entries.filter { $0.receipt == nil }
        }
    }

    public func allEntries() -> [JournalEntry] {
        lock.withLock { entries }
    }

    private func persistLocked() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try? data.write(to: fileURL, options: [.atomic])
            #endif
        }
    }
}

public protocol EvidenceLookupProtocol: Sendable {
    func findPersistedObjectId(for entry: JournalEntry) async -> String?
}

/// Uygulama yeniden açıldığında makbuzu alınmamış adımları uzlaştırır.
/// Kanıt bulunursa tamamlandı sayar; aksi halde "Sonuç doğrulanamadı" işaretler ve otomatik tekrarlamaz.
public struct ReconciliationEngine: Sendable {
    private let evidenceLookup: EvidenceLookupProtocol
    private let clock: ClockProtocol

    public init(evidenceLookup: EvidenceLookupProtocol, clock: ClockProtocol = SystemClock()) {
        self.evidenceLookup = evidenceLookup
        self.clock = clock
    }

    public func reconcileInterruptedEntries(in journal: WriteAheadJournal) async -> [ActionReceipt] {
        let pending = journal.unresolvedEntries()
        var reconciled: [ActionReceipt] = []

        for entry in pending {
            if let verifiedId = await evidenceLookup.findPersistedObjectId(for: entry) {
                let receipt = ActionReceipt(
                    taskId: entry.taskId,
                    revisionNumber: entry.revisionNumber,
                    stepId: entry.stepId,
                    executorName: "ReconciliationEngine",
                    outcome: .succeeded,
                    externalObjectId: verifiedId,
                    timestamp: clock.now(),
                    canUndo: false,
                    spokenVerbTR: "Önceki kayıt doğrulandı",
                    spokenVerbAZ: "Əvvəlki qeyd təsdiqləndi",
                    detail: "Sistem kanıtı eşleşti: \(verifiedId)"
                )
                journal.completeStep(
                    taskId: entry.taskId,
                    revisionNumber: entry.revisionNumber,
                    stepId: entry.stepId,
                    receipt: receipt
                )
                reconciled.append(receipt)
            } else {
                let receipt = ActionReceipt(
                    taskId: entry.taskId,
                    revisionNumber: entry.revisionNumber,
                    stepId: entry.stepId,
                    executorName: "ReconciliationEngine",
                    outcome: .uncertain,
                    externalObjectId: nil,
                    timestamp: clock.now(),
                    canUndo: false,
                    spokenVerbTR: "Sonuç doğrulanamadı",
                    spokenVerbAZ: "Nəticə təsdiqlənmədi",
                    detail: "Uygulama kapanmadan önce '\(entry.titleOrTarget)' işleminin makbuzu alınamadı; otomatik tekrar yapılmadı."
                )
                journal.completeStep(
                    taskId: entry.taskId,
                    revisionNumber: entry.revisionNumber,
                    stepId: entry.stepId,
                    receipt: receipt
                )
                reconciled.append(receipt)
            }
        }
        return reconciled
    }
}
