import Foundation

public enum TaskSource: String, Codable, Sendable, Equatable {
    case siri
    case inAppVoice
    case inAppText
    case shareExtension
    case vocalShortcut
    case actionButton
}

public enum TaskTerminalSummary: Codable, Equatable, Sendable {
    case completed
    case partiallyCompleted
    case cancelled
    case awaitingUserAction
    case unknownOutcome
    case unsupported(String)
    case refused(String)
}

public enum TaskLifecycleState: Codable, Equatable, Sendable {
    case received
    case awaitingClarification(String)
    case awaitingConfirmation
    case executing
    case finished(TaskTerminalSummary)
}

public struct AgentTask: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: TaskSource
    public let locale: String
    public var selectedModelPath: String
    public var state: TaskLifecycleState
    public let createdAt: Date
    public var updatedAt: Date
    public var currentRevisionNumber: Int
    public let isContinuation: Bool
    public let rawUtterance: String

    public init(
        id: UUID = UUID(),
        source: TaskSource,
        locale: String = "tr_TR",
        selectedModelPath: String,
        state: TaskLifecycleState = .received,
        createdAt: Date,
        updatedAt: Date? = nil,
        currentRevisionNumber: Int = 1,
        isContinuation: Bool = false,
        rawUtterance: String
    ) {
        self.id = id
        self.source = source
        self.locale = locale
        self.selectedModelPath = selectedModelPath
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.currentRevisionNumber = currentRevisionNumber
        self.isContinuation = isContinuation
        self.rawUtterance = rawUtterance
    }
}

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case notesCreate = "notes.create"
    case notesSearch = "notes.search"
    case calendarRead = "calendar.read"
    case calendarCreate = "calendar.create"
    case remindersCreate = "reminders.create"
    case remindersRead = "reminders.read"
    case messagesCompose = "messages.compose"
    case mailCompose = "mail.compose"
    case shareSheet = "share.sheet"
    case phoneCall = "phone.call"
    case mapsDirections = "maps.directions"
    case mapsEstimateETA = "maps.estimateETA"
    case shortcutsRun = "shortcuts.run"
    case textSummarizeAndNote = "text.summarizeAndNote"
    case assistantReply = "assistant.reply"
    case briefingCompose = "briefing.compose"
    case memoryRemember = "memory.remember"
    case memoryRecall = "memory.recall"
    case memoryForget = "memory.forget"
    case alarmCreate = "alarm.create"
}

public enum ConfirmationKind: String, Codable, Sendable, Equatable {
    case none
    case undoableLocalWrite
    case explicitSummary
    case shortcutPreview
    case systemUIHandoff
}

public enum StepExecutionStatus: Codable, Equatable, Sendable {
    case pending
    case ready
    case inUserInterface
    case completed
    case cancelled
    case failed(String)
    case uncertain(String)
    case skippedDueToDependency
}

public struct ActionParameters: Codable, Equatable, Sendable {
    public var title: String?
    public var noteContent: String?
    public var query: String?
    public var startISO8601: String?
    public var durationMinutes: Int?
    public var dueISO8601: String?
    public var recipientQuery: String?
    public var resolvedRecipientHandle: String?
    public var body: String?
    public var subject: String?
    public var destinationQuery: String?
    public var transportMode: String?
    public var shortcutLabel: String?
    public var shortcutInput: String?
    public var untrustedSourceText: String?
    public var urlString: String?
    public var locationRequested: Bool

    public init(
        title: String? = nil,
        noteContent: String? = nil,
        query: String? = nil,
        startISO8601: String? = nil,
        durationMinutes: Int? = nil,
        dueISO8601: String? = nil,
        recipientQuery: String? = nil,
        resolvedRecipientHandle: String? = nil,
        body: String? = nil,
        subject: String? = nil,
        destinationQuery: String? = nil,
        transportMode: String? = nil,
        shortcutLabel: String? = nil,
        shortcutInput: String? = nil,
        untrustedSourceText: String? = nil,
        urlString: String? = nil,
        locationRequested: Bool = false
    ) {
        self.title = title
        self.noteContent = noteContent
        self.query = query
        self.startISO8601 = startISO8601
        self.durationMinutes = durationMinutes
        self.dueISO8601 = dueISO8601
        self.recipientQuery = recipientQuery
        self.resolvedRecipientHandle = resolvedRecipientHandle
        self.body = body
        self.subject = subject
        self.destinationQuery = destinationQuery
        self.transportMode = transportMode
        self.shortcutLabel = shortcutLabel
        self.shortcutInput = shortcutInput
        self.untrustedSourceText = untrustedSourceText
        self.urlString = urlString
        self.locationRequested = locationRequested
    }
}

public struct ActionStep: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let action: ActionKind
    public var parameters: ActionParameters
    public var dependsOn: [String]
    public var confirmationKind: ConfirmationKind
    public var status: StepExecutionStatus
    public var isUndoable: Bool

    public init(
        id: String,
        action: ActionKind,
        parameters: ActionParameters = ActionParameters(),
        dependsOn: [String] = [],
        confirmationKind: ConfirmationKind? = nil,
        status: StepExecutionStatus = .pending,
        isUndoable: Bool? = nil
    ) {
        self.id = id
        self.action = action
        self.parameters = parameters
        self.dependsOn = dependsOn
        let spec = ActionCatalog.spec(for: action)
        self.confirmationKind = confirmationKind ?? spec.defaultConfirmation
        self.status = status
        self.isUndoable = isUndoable ?? spec.isUndoable
    }
}

public struct PlanRevision: Codable, Equatable, Sendable {
    public let revisionNumber: Int
    public let taskId: UUID
    public var steps: [ActionStep]
    public let approvalDigest: String
    public var isInvalidated: Bool
    public let createdAt: Date

    public init(
        revisionNumber: Int,
        taskId: UUID,
        steps: [ActionStep],
        approvalDigest: String,
        isInvalidated: Bool = false,
        createdAt: Date
    ) {
        self.revisionNumber = revisionNumber
        self.taskId = taskId
        self.steps = steps
        self.approvalDigest = approvalDigest
        self.isInvalidated = isInvalidated
        self.createdAt = createdAt
    }
}

public enum ReceiptOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case cancelled
    case failed
    case handedOffToUserInterface
    case uncertain
}

public struct ActionReceipt: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskId: UUID
    public let revisionNumber: Int
    public let stepId: String
    public let executorName: String
    public let outcome: ReceiptOutcome
    public let externalObjectId: String?
    public let timestamp: Date
    public let canUndo: Bool
    public let spokenVerbTR: String
    public let spokenVerbAZ: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        taskId: UUID,
        revisionNumber: Int,
        stepId: String,
        executorName: String,
        outcome: ReceiptOutcome,
        externalObjectId: String? = nil,
        timestamp: Date,
        canUndo: Bool,
        spokenVerbTR: String,
        spokenVerbAZ: String,
        detail: String
    ) {
        self.id = id
        self.taskId = taskId
        self.revisionNumber = revisionNumber
        self.stepId = stepId
        self.executorName = executorName
        self.outcome = outcome
        self.externalObjectId = externalObjectId
        self.timestamp = timestamp
        self.canUndo = canUndo
        self.spokenVerbTR = spokenVerbTR
        self.spokenVerbAZ = spokenVerbAZ
        self.detail = detail
    }
}

public enum ShortcutInputKind: String, Codable, Sendable, Equatable {
    case none
    case text
}

public enum ShortcutTestStatus: String, Codable, Sendable, Equatable {
    case untested
    case verified
    case missingOrRenamed
    case failed
}

public struct ShortcutBinding: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var userLabel: String
    public var shortcutName: String
    public var acceptedInput: ShortcutInputKind
    public var lastTestedAt: Date?
    public var lastTestStatus: ShortcutTestStatus

    public init(
        id: UUID = UUID(),
        userLabel: String,
        shortcutName: String,
        acceptedInput: ShortcutInputKind = .text,
        lastTestedAt: Date? = nil,
        lastTestStatus: ShortcutTestStatus = .untested
    ) {
        self.id = id
        self.userLabel = userLabel
        self.shortcutName = shortcutName
        self.acceptedInput = acceptedInput
        self.lastTestedAt = lastTestedAt
        self.lastTestStatus = lastTestStatus
    }
}
