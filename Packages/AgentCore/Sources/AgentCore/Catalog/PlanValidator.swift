import Foundation
import CryptoKit

public enum PlanValidationError: Error, Equatable, Sendable {
    case emptyPlan
    case exceedsMaxStepLimit(count: Int, max: Int)
    case unknownAction(String)
    case duplicateStepID(String)
    case unknownDependency(stepId: String, missingDependency: String)
    case cyclicDependency
    case invalidDateFormat(stepId: String, value: String)
    case invalidDuration(stepId: String, duration: Int)
    case missingRequiredParameter(stepId: String, parameter: String)
    case outOfScopeURL(stepId: String, url: String)
    case locationReminderRequiresTimeOrShortcut(stepId: String)
    case causalClaimWithoutDependency(stepId: String)
}

public struct RawModelStepInput: Codable, Equatable, Sendable {
    public let id: String
    public let action: String
    public let parameters: ActionParameters
    public let dependsOn: [String]

    public init(
        id: String,
        action: String,
        parameters: ActionParameters = ActionParameters(),
        dependsOn: [String] = []
    ) {
        self.id = id
        self.action = action
        self.parameters = parameters
        self.dependsOn = dependsOn
    }
}

/// Tüm adım ve parametre alanlarını tip-etiketli / uzunluk-önekli kanonik SHA-256 ile özetler.
/// `nil`, `""` ve `0` değerlerinin çarpışmasını tamamen önler.
public enum CanonicalApprovalDigest {
    private static let domainTag = Data("iAgent.CanonicalApprovalDigest.v2\0".utf8)

    public static func compute(
        taskId: UUID,
        revisionNumber: Int,
        steps: [ActionStep]
    ) -> String {
        var buffer = Data()
        buffer.append(domainTag)
        appendString(taskId.uuidString, to: &buffer)
        appendInt(revisionNumber, to: &buffer)
        appendInt(steps.count, to: &buffer)

        for step in steps {
            appendString(step.id, to: &buffer)
            appendString(step.action.rawValue, to: &buffer)
            appendString(step.confirmationKind.rawValue, to: &buffer)
            appendBool(step.isUndoable, to: &buffer)
            appendStringArray(step.dependsOn, to: &buffer)

            let p = step.parameters
            appendOptionalString(p.title, to: &buffer)
            appendOptionalString(p.noteContent, to: &buffer)
            appendOptionalString(p.query, to: &buffer)
            appendOptionalString(p.startISO8601, to: &buffer)
            appendOptionalInt(p.durationMinutes, to: &buffer)
            appendOptionalString(p.dueISO8601, to: &buffer)
            appendOptionalString(p.recipientQuery, to: &buffer)
            appendOptionalString(p.resolvedRecipientHandle, to: &buffer)
            appendOptionalString(p.body, to: &buffer)
            appendOptionalString(p.subject, to: &buffer)
            appendOptionalString(p.destinationQuery, to: &buffer)
            appendOptionalString(p.transportMode, to: &buffer)
            appendOptionalString(p.shortcutLabel, to: &buffer)
            appendOptionalString(p.shortcutInput, to: &buffer)
            appendOptionalString(p.untrustedSourceText, to: &buffer)
            appendOptionalString(p.urlString, to: &buffer)
            appendBool(p.locationRequested, to: &buffer)
        }

        let hash = SHA256.hash(data: buffer)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func rebuildRevisionWithUpdatedSteps(
        from previous: inout PlanRevision,
        transform: ([ActionStep]) throws -> [ActionStep],
        now: Date = Date()
    ) rethrows -> PlanRevision {
        previous.isInvalidated = true
        let updatedSteps = try transform(previous.steps)
        let nextRevisionNumber = previous.revisionNumber + 1
        let digest = compute(
            taskId: previous.taskId,
            revisionNumber: nextRevisionNumber,
            steps: updatedSteps
        )
        return PlanRevision(
            revisionNumber: nextRevisionNumber,
            taskId: previous.taskId,
            steps: updatedSteps,
            approvalDigest: digest,
            isInvalidated: false,
            createdAt: now
        )
    }

    private static func appendString(_ value: String, to buffer: inout Data) {
        buffer.append(0x53) // 'S'
        let utf8 = Data(value.utf8)
        appendUInt64(UInt64(utf8.count), to: &buffer)
        buffer.append(utf8)
    }

    private static func appendOptionalString(_ value: String?, to buffer: inout Data) {
        if let value {
            appendString(value, to: &buffer)
        } else {
            buffer.append(0x4E) // 'N'
        }
    }

    private static func appendInt(_ value: Int, to buffer: inout Data) {
        buffer.append(0x49) // 'I'
        var bigEndian = Int64(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { buffer.append(contentsOf: $0) }
    }

    private static func appendOptionalInt(_ value: Int?, to buffer: inout Data) {
        if let value {
            appendInt(value, to: &buffer)
        } else {
            buffer.append(0x4E) // 'N'
        }
    }

    private static func appendBool(_ value: Bool, to buffer: inout Data) {
        buffer.append(0x42) // 'B'
        buffer.append(value ? 0x01 : 0x00)
    }

    private static func appendStringArray(_ values: [String], to buffer: inout Data) {
        buffer.append(0x41) // 'A'
        appendUInt64(UInt64(values.count), to: &buffer)
        for item in values {
            appendString(item, to: &buffer)
        }
    }

    private static func appendUInt64(_ value: UInt64, to buffer: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { buffer.append(contentsOf: $0) }
    }
}

/// Model veya kural tabanlı ayrıştırıcıdan gelen adımları şemaya göre doğrular.
public enum PlanValidator {
    private static let allowedURLSchemes = Set(["tel", "telprompt", "shortcuts", "maps", "whatsapp"])

    public static func validateAndBuildRevision(
        taskId: UUID,
        revisionNumber: Int,
        rawSteps: [RawModelStepInput],
        now: Date
    ) throws -> PlanRevision {
        guard !rawSteps.isEmpty else {
            throw PlanValidationError.emptyPlan
        }
        guard rawSteps.count <= ActionCatalog.maxStepsPerPlan else {
            throw PlanValidationError.exceedsMaxStepLimit(
                count: rawSteps.count,
                max: ActionCatalog.maxStepsPerPlan
            )
        }

        var seenIDs = Set<String>()
        var typedSteps: [ActionStep] = []

        for raw in rawSteps {
            guard seenIDs.insert(raw.id).inserted else {
                throw PlanValidationError.duplicateStepID(raw.id)
            }
            guard let actionKind = ActionKind(rawValue: raw.action) else {
                throw PlanValidationError.unknownAction(raw.action)
            }
            let step = ActionStep(
                id: raw.id,
                action: actionKind,
                parameters: raw.parameters,
                dependsOn: raw.dependsOn
            )
            try validateStepParameters(step)
            typedSteps.append(step)
        }

        try validateDAGAndCausalClaims(typedSteps)
        let orderedSteps = topologicalOrder(typedSteps)
        let digest = computeApprovalDigest(
            taskId: taskId,
            revisionNumber: revisionNumber,
            steps: orderedSteps
        )

        return PlanRevision(
            revisionNumber: revisionNumber,
            taskId: taskId,
            steps: orderedSteps,
            approvalDigest: digest,
            isInvalidated: false,
            createdAt: now
        )
    }

    public static func computeApprovalDigest(
        taskId: UUID,
        revisionNumber: Int,
        steps: [ActionStep]
    ) -> String {
        CanonicalApprovalDigest.compute(
            taskId: taskId,
            revisionNumber: revisionNumber,
            steps: steps
        )
    }

    private static func validateStepParameters(_ step: ActionStep) throws {
        let params = step.parameters
        if let urlStr = params.urlString, !urlStr.isEmpty {
            guard let url = URL(string: urlStr),
                  let scheme = url.scheme?.lowercased(),
                  allowedURLSchemes.contains(scheme) else {
                throw PlanValidationError.outOfScopeURL(stepId: step.id, url: urlStr)
            }
        }

        switch step.action {
        case .notesCreate, .textSummarizeAndNote:
            if (params.noteContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PlanValidationError.missingRequiredParameter(stepId: step.id, parameter: "noteContent")
            }
        case .memoryRemember:
            let hasContent = !(params.noteContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasQuery = !(params.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasContent && !hasQuery {
                throw PlanValidationError.missingRequiredParameter(stepId: step.id, parameter: "noteContent")
            }
        case .calendarCreate:
            if (params.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PlanValidationError.missingRequiredParameter(stepId: step.id, parameter: "title")
            }
            guard let start = params.startISO8601, parseISO8601(start) != nil else {
                throw PlanValidationError.invalidDateFormat(stepId: step.id, value: params.startISO8601 ?? "")
            }
            let duration = params.durationMinutes ?? 30
            if duration <= 0 || duration > 1440 {
                throw PlanValidationError.invalidDuration(stepId: step.id, duration: duration)
            }
        case .remindersCreate:
            if params.locationRequested {
                throw PlanValidationError.locationReminderRequiresTimeOrShortcut(stepId: step.id)
            }
            if (params.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PlanValidationError.missingRequiredParameter(stepId: step.id, parameter: "title")
            }
            guard let due = params.dueISO8601, parseISO8601(due) != nil else {
                throw PlanValidationError.invalidDateFormat(stepId: step.id, value: params.dueISO8601 ?? "")
            }
        case .mapsDirections, .mapsEstimateETA:
            if (params.destinationQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PlanValidationError.missingRequiredParameter(stepId: step.id, parameter: "destinationQuery")
            }
        case .shortcutsRun:
            if (params.shortcutLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PlanValidationError.missingRequiredParameter(stepId: step.id, parameter: "shortcutLabel")
            }
        default:
            break
        }
    }

    private static func validateDAGAndCausalClaims(_ steps: [ActionStep]) throws {
        let stepMap = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        for step in steps {
            for dep in step.dependsOn {
                guard stepMap[dep] != nil else {
                    throw PlanValidationError.unknownDependency(stepId: step.id, missingDependency: dep)
                }
            }
            if [.messagesCompose, .mailCompose, .shareSheet].contains(step.action),
               let body = step.parameters.body {
                let normalizedBody = TurkicTextNormalizer.normalize(body)
                let claimsWrite = ["ekledim", "kaydettim", "olusturdum", "elave etdim"].contains {
                    normalizedBody.contains($0)
                }
                if claimsWrite {
                    let hasWriteDep = step.dependsOn.contains { depId in
                        guard let depStep = stepMap[depId] else { return false }
                        return depStep.action == .calendarCreate
                            || depStep.action == .remindersCreate
                            || depStep.action == .alarmCreate
                            || depStep.action == .notesCreate
                            || depStep.action == .memoryRemember
                    }
                    if !hasWriteDep {
                        throw PlanValidationError.causalClaimWithoutDependency(stepId: step.id)
                    }
                }
            }
        }

        // Cycle check via Kahn's algorithm
        var inDegree = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.dependsOn.count) })
        var dependents: [String: [String]] = [:]
        for step in steps {
            for dep in step.dependsOn {
                dependents[dep, default: []].append(step.id)
            }
        }
        var queue = steps.filter { (inDegree[$0.id] ?? 0) == 0 }.map(\.id)
        var visited = 0
        while !queue.isEmpty {
            let current = queue.removeFirst()
            visited += 1
            for next in dependents[current, default: []] {
                inDegree[next, default: 0] -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }
        guard visited == steps.count else {
            throw PlanValidationError.cyclicDependency
        }
    }

    private static func topologicalOrder(_ steps: [ActionStep]) -> [ActionStep] {
        let stepMap = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0) })
        var inDegree = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.dependsOn.count) })
        var dependents: [String: [String]] = [:]
        for step in steps {
            for dep in step.dependsOn {
                dependents[dep, default: []].append(step.id)
            }
        }
        var queue = steps.filter { (inDegree[$0.id] ?? 0) == 0 }.map(\.id)
        var result: [ActionStep] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let s = stepMap[current] {
                result.append(s)
            }
            for next in dependents[current, default: []] {
                inDegree[next, default: 0] -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }
        return result
    }

    public static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
