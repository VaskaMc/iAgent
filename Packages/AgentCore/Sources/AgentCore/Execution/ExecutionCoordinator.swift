import Foundation

public protocol ClockProtocol: Sendable {
    func now() -> Date
}

public struct SystemClock: ClockProtocol, Sendable {
    public init() {}
    public func now() -> Date { Date() }
}

public final class FixedTestClock: ClockProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(date: Date) {
        self.current = date
    }

    public func now() -> Date {
        lock.withLock { current }
    }

    public func advance(by seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
        }
    }
}

public struct ConfirmationGrant: Codable, Equatable, Sendable {
    public let taskId: UUID
    public let revisionNumber: Int
    public let stepIds: [String]
    public let targetSummary: String
    public let approvalDigest: String
    public let grantedAt: Date

    public init(
        taskId: UUID,
        revisionNumber: Int,
        stepIds: [String],
        targetSummary: String,
        approvalDigest: String,
        grantedAt: Date
    ) {
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.stepIds = stepIds
        self.targetSummary = targetSummary
        self.approvalDigest = approvalDigest
        self.grantedAt = grantedAt
    }
}

public enum PlanApprovalError: Error, Equatable, Sendable {
    case staleRevision(expected: Int, received: Int)
    case invalidatedRevision(Int)
    case digestMismatch
    case unauthorizedSteps([String])
    case duplicateExecutionBlocked(stepId: String)
    case untrustedInstructionInjection(String)
}

/// Paylaşılan belge, web metni veya kestirme dönüşünü yalnız veri olarak işler.
public struct UntrustedInputEnvelope: Equatable, Sendable {
    public let sourceLabel: String
    public let rawText: String

    public init(sourceLabel: String, rawText: String) {
        self.sourceLabel = sourceLabel
        self.rawText = rawText
    }
}

public enum UntrustedContentPolicy {
    /// Kaynak metin içinden çıkan komutların yeni eylem başlatmasını engeller.
    public static func enforceSummarizeOnlyPlan(
        untrusted: UntrustedInputEnvelope,
        proposedSteps: [RawModelStepInput]
    ) throws -> [RawModelStepInput] {
        for step in proposedSteps {
            if step.action != ActionKind.textSummarizeAndNote.rawValue &&
               step.action != ActionKind.notesCreate.rawValue &&
               step.action != ActionKind.assistantReply.rawValue {
                throw PlanApprovalError.untrustedInstructionInjection(
                    "Paylaşılan içerikten çıkan '\(step.action)' eylemi engellendi."
                )
            }
        }
        return proposedSteps
    }
}

/// Aynı görev/revizyon/adım için yinelenen yürütmeleri önleyen tek yürütme kilidi.
public final class ExecutionLeaseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var acquiredKeys = Set<String>()

    public init() {}

    public func tryAcquire(taskId: UUID, revisionNumber: Int, stepId: String) -> Bool {
        let key = "\(taskId.uuidString):\(revisionNumber):\(stepId)"
        return lock.withLock {
            acquiredKeys.insert(key).inserted
        }
    }
}

public protocol StepExecutorProtocol: Sendable {
    func execute(step: ActionStep, task: AgentTask, revisionNumber: Int, now: Date) async throws -> ActionReceipt
}

/// Onay geçidi, plan revizyon düzenlemeleri ve adım bağımlılıklarını yöneten çekirdek yürütücü.
public final class ExecutionCoordinator: @unchecked Sendable {
    private let clock: ClockProtocol
    private let leaseStore: ExecutionLeaseStore
    private let journal: WriteAheadJournal?

    public init(
        clock: ClockProtocol = SystemClock(),
        leaseStore: ExecutionLeaseStore = ExecutionLeaseStore(),
        journal: WriteAheadJournal? = nil
    ) {
        self.clock = clock
        self.leaseStore = leaseStore
        self.journal = journal
    }

    public func issueGrant(for revision: PlanRevision, targetSummary: String) throws -> ConfirmationGrant {
        guard !revision.isInvalidated else {
            throw PlanApprovalError.invalidatedRevision(revision.revisionNumber)
        }
        return ConfirmationGrant(
            taskId: revision.taskId,
            revisionNumber: revision.revisionNumber,
            stepIds: revision.steps.map(\.id),
            targetSummary: targetSummary,
            approvalDigest: revision.approvalDigest,
            grantedAt: clock.now()
        )
    }

    /// Mevcut bekleyen plandan bir adımı çıkarıp yeni revizyon üretir ve eski revizyonu geçersiz kılar.
    public func removeStep(
        stepId: String,
        from previous: inout PlanRevision
    ) throws -> PlanRevision {
        previous.isInvalidated = true
        let remaining = previous.steps
            .filter { $0.id != stepId }
            .map {
                RawModelStepInput(
                    id: $0.id,
                    action: $0.action.rawValue,
                    parameters: $0.parameters,
                    dependsOn: $0.dependsOn.filter { $0 != stepId }
                )
            }
        return try PlanValidator.validateAndBuildRevision(
            taskId: previous.taskId,
            revisionNumber: previous.revisionNumber + 1,
            rawSteps: remaining,
            now: clock.now()
        )
    }

    /// Mevcut plandaki bir adımın başlangıç/bitiş saatini kaydırır ve eski onayı geçersiz kılar.
    public func shiftStepTime(
        stepId: String,
        minutes: Int,
        from previous: inout PlanRevision
    ) throws -> PlanRevision {
        previous.isInvalidated = true
        let updatedRaw = try previous.steps.map { step -> RawModelStepInput in
            var params = step.parameters
            if step.id == stepId {
                if let startStr = params.startISO8601,
                   let parsed = PlanValidator.parseISO8601(startStr) {
                    params.startISO8601 = formatISO8601PreservingOffset(
                        parsed.addingTimeInterval(TimeInterval(minutes * 60)),
                        reference: startStr
                    )
                }
                if let dueStr = params.dueISO8601,
                   let parsed = PlanValidator.parseISO8601(dueStr) {
                    params.dueISO8601 = formatISO8601PreservingOffset(
                        parsed.addingTimeInterval(TimeInterval(minutes * 60)),
                        reference: dueStr
                    )
                }
            }
            return RawModelStepInput(
                id: step.id,
                action: step.action.rawValue,
                parameters: params,
                dependsOn: step.dependsOn
            )
        }
        return try PlanValidator.validateAndBuildRevision(
            taskId: previous.taskId,
            revisionNumber: previous.revisionNumber + 1,
            rawSteps: updatedRaw,
            now: clock.now()
        )
    }

    public func execute(
        task: inout AgentTask,
        revision: inout PlanRevision,
        grant: ConfirmationGrant,
        executor: StepExecutorProtocol
    ) async throws -> [ActionReceipt] {
        guard !revision.isInvalidated else {
            throw PlanApprovalError.invalidatedRevision(revision.revisionNumber)
        }
        guard grant.taskId == task.id,
              grant.revisionNumber == revision.revisionNumber else {
            throw PlanApprovalError.staleRevision(
                expected: revision.revisionNumber,
                received: grant.revisionNumber
            )
        }
        guard grant.approvalDigest == revision.approvalDigest else {
            throw PlanApprovalError.digestMismatch
        }

        let grantedSet = Set(grant.stepIds)
        let missingFromGrant = revision.steps.map(\.id).filter { !grantedSet.contains($0) }
        guard missingFromGrant.isEmpty else {
            throw PlanApprovalError.unauthorizedSteps(missingFromGrant)
        }

        task.state = .executing
        task.updatedAt = clock.now()

        var receipts: [ActionReceipt] = []
        var stepStatuses: [String: StepExecutionStatus] = [:]

        for index in revision.steps.indices {
            let step = revision.steps[index]
            let upstreamBlocked = step.dependsOn.contains { depId in
                guard let status = stepStatuses[depId] else { return true }
                switch status {
                case .completed:
                    return false
                default:
                    return true
                }
            }

            if upstreamBlocked {
                revision.steps[index].status = .skippedDueToDependency
                stepStatuses[step.id] = .skippedDueToDependency
                continue
            }

            guard leaseStore.tryAcquire(
                taskId: task.id,
                revisionNumber: revision.revisionNumber,
                stepId: step.id
            ) else {
                throw PlanApprovalError.duplicateExecutionBlocked(stepId: step.id)
            }

            journal?.beginStep(taskId: task.id, revisionNumber: revision.revisionNumber, step: step, now: clock.now())

            do {
                let receipt = try await executor.execute(
                    step: step,
                    task: task,
                    revisionNumber: revision.revisionNumber,
                    now: clock.now()
                )
                journal?.completeStep(
                    taskId: task.id,
                    revisionNumber: revision.revisionNumber,
                    stepId: step.id,
                    receipt: receipt
                )
                receipts.append(receipt)

                let mappedStatus: StepExecutionStatus
                switch receipt.outcome {
                case .succeeded:
                    mappedStatus = .completed
                case .cancelled:
                    mappedStatus = .cancelled
                case .failed:
                    mappedStatus = .failed(receipt.detail)
                case .handedOffToUserInterface:
                    mappedStatus = .inUserInterface
                case .uncertain:
                    mappedStatus = .uncertain(receipt.detail)
                }
                revision.steps[index].status = mappedStatus
                stepStatuses[step.id] = mappedStatus
            } catch {
                let failMsg = error.localizedDescription
                let receipt = ActionReceipt(
                    taskId: task.id,
                    revisionNumber: revision.revisionNumber,
                    stepId: step.id,
                    executorName: "ExecutionCoordinator",
                    outcome: .failed,
                    timestamp: clock.now(),
                    canUndo: false,
                    spokenVerbTR: "İşlem başarısız oldu",
                    spokenVerbAZ: "Əməliyyat uğursuz oldu",
                    detail: failMsg
                )
                journal?.completeStep(
                    taskId: task.id,
                    revisionNumber: revision.revisionNumber,
                    stepId: step.id,
                    receipt: receipt
                )
                receipts.append(receipt)
                revision.steps[index].status = .failed(failMsg)
                stepStatuses[step.id] = .failed(failMsg)
            }
        }

        task.state = .finished(Self.summarizeTerminalState(steps: revision.steps))
        task.updatedAt = clock.now()
        return receipts
    }

    public static func summarizeTerminalState(steps: [ActionStep]) -> TaskTerminalSummary {
        let completedCount = steps.filter {
            if case .completed = $0.status { return true }
            return false
        }.count
        let cancelledCount = steps.filter {
            if case .cancelled = $0.status { return true }
            return false
        }.count
        let uncertainCount = steps.filter {
            if case .uncertain = $0.status { return true }
            return false
        }.count
        let uiCount = steps.filter {
            if case .inUserInterface = $0.status { return true }
            return false
        }.count

        if uncertainCount > 0 && completedCount == 0 {
            return .unknownOutcome
        }
        if uiCount > 0 && completedCount == 0 {
            return .awaitingUserAction
        }
        if completedCount == steps.count {
            return .completed
        }
        if cancelledCount == steps.count {
            return .cancelled
        }
        if completedCount > 0 {
            return .partiallyCompleted
        }
        return .unknownOutcome
    }

    private func formatISO8601PreservingOffset(_ date: Date, reference: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if reference.hasSuffix("+04:00"), let baku = TimeZone(identifier: "Asia/Baku") {
            formatter.timeZone = baku
        } else if reference.hasSuffix("+03:00"), let ist = TimeZone(identifier: "Europe/Istanbul") {
            formatter.timeZone = ist
        }
        return formatter.string(from: date)
    }
}
