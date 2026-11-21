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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = steps.map {
            "\($0.id)|\($0.action.rawValue)|\($0.parameters.title ?? "")|\($0.parameters.startISO8601 ?? "")|\($0.parameters.durationMinutes ?? 0)|\($0.parameters.dueISO8601 ?? "")|\($0.parameters.recipientQuery ?? "")|\($0.parameters.resolvedRecipientHandle ?? "")|\($0.parameters.body ?? "")|\($0.parameters.shortcutLabel ?? "")|\($0.dependsOn.joined(separator: ","))"
        }.joined(separator: ";")
        let full = "\(taskId.uuidString)#\(revisionNumber)#\(payload)"
        let hash = SHA256.hash(data: Data(full.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
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
        case .mapsDirections:
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
                        return depStep.action == .calendarCreate || depStep.action == .remindersCreate
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
