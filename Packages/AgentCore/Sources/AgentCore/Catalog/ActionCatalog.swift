import Foundation

public enum RequiredPermission: String, Codable, Sendable, Equatable {
    case none
    case calendarRead
    case calendarWriteOnly
    case remindersFull
    case contactsRead
    case alarmKit
    case notifications
}

public enum DataSensitivity: String, Codable, Sendable, Equatable {
    case publicCommand
    case personalRead
    case personalWrite
    case outboundCommunication
    case externalBridge
}

public enum EvidenceType: String, Codable, Sendable, Equatable {
    case localNoteID
    case eventKitScheduleRead
    case eventKitIdentifier
    case reminderIdentifierWithAlarm
    case systemComposerResult
    case systemShareOrDialHandoff
    case mapItemHandoff
    case shortcutCallbackResult
    case textOnlyResponse
    case briefingSynthesisReport
    case memoryVaultRecord
    case alarmIdentifier
    case etaCalculation
}

/// Hiyerarşik v2 planlar için faz ve toplam adım bütçe sınırları.
public struct PlanBudgetLimits: Codable, Equatable, Sendable {
    public let maxStepsPerPhase: Int
    public let maxTotalSteps: Int

    public init(maxStepsPerPhase: Int = 8, maxTotalSteps: Int = 32) {
        self.maxStepsPerPhase = maxStepsPerPhase
        self.maxTotalSteps = maxTotalSteps
    }

    public static let v2Default = PlanBudgetLimits(maxStepsPerPhase: 8, maxTotalSteps: 32)
}

public struct ActionSpec: Sendable, Equatable {
    public let kind: ActionKind
    public let requiredPermission: RequiredPermission
    public let sensitivity: DataSensitivity
    public let defaultConfirmation: ConfirmationKind
    public let isUndoable: Bool
    public let evidenceType: EvidenceType
    public let requiresUnlockedDevice: Bool

    public init(
        kind: ActionKind,
        requiredPermission: RequiredPermission,
        sensitivity: DataSensitivity,
        defaultConfirmation: ConfirmationKind,
        isUndoable: Bool,
        evidenceType: EvidenceType,
        requiresUnlockedDevice: Bool
    ) {
        self.kind = kind
        self.requiredPermission = requiredPermission
        self.sensitivity = sensitivity
        self.defaultConfirmation = defaultConfirmation
        self.isUndoable = isUndoable
        self.evidenceType = evidenceType
        self.requiresUnlockedDevice = requiresUnlockedDevice
    }
}

/// Bölüm 3'teki ilk sürüm yetenek kataloğunun merkezi şeması.
public enum ActionCatalog {
    public static let maxStepsPerPlan = 8

    public static let allSpecs: [ActionKind: ActionSpec] = [
        .notesCreate: ActionSpec(
            kind: .notesCreate,
            requiredPermission: .none,
            sensitivity: .personalWrite,
            defaultConfirmation: .undoableLocalWrite,
            isUndoable: true,
            evidenceType: .localNoteID,
            requiresUnlockedDevice: false
        ),
        .notesSearch: ActionSpec(
            kind: .notesSearch,
            requiredPermission: .none,
            sensitivity: .personalRead,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .localNoteID,
            requiresUnlockedDevice: true
        ),
        .calendarRead: ActionSpec(
            kind: .calendarRead,
            requiredPermission: .calendarRead,
            sensitivity: .personalRead,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .eventKitScheduleRead,
            requiresUnlockedDevice: true
        ),
        .calendarCreate: ActionSpec(
            kind: .calendarCreate,
            requiredPermission: .calendarWriteOnly,
            sensitivity: .personalWrite,
            defaultConfirmation: .explicitSummary,
            isUndoable: true,
            evidenceType: .eventKitIdentifier,
            requiresUnlockedDevice: true
        ),
        .remindersCreate: ActionSpec(
            kind: .remindersCreate,
            requiredPermission: .remindersFull,
            sensitivity: .personalWrite,
            defaultConfirmation: .explicitSummary,
            isUndoable: true,
            evidenceType: .reminderIdentifierWithAlarm,
            requiresUnlockedDevice: true
        ),
        .messagesCompose: ActionSpec(
            kind: .messagesCompose,
            requiredPermission: .contactsRead,
            sensitivity: .outboundCommunication,
            defaultConfirmation: .systemUIHandoff,
            isUndoable: false,
            evidenceType: .systemComposerResult,
            requiresUnlockedDevice: true
        ),
        .mailCompose: ActionSpec(
            kind: .mailCompose,
            requiredPermission: .contactsRead,
            sensitivity: .outboundCommunication,
            defaultConfirmation: .systemUIHandoff,
            isUndoable: false,
            evidenceType: .systemComposerResult,
            requiresUnlockedDevice: true
        ),
        .shareSheet: ActionSpec(
            kind: .shareSheet,
            requiredPermission: .none,
            sensitivity: .outboundCommunication,
            defaultConfirmation: .systemUIHandoff,
            isUndoable: false,
            evidenceType: .systemShareOrDialHandoff,
            requiresUnlockedDevice: true
        ),
        .phoneCall: ActionSpec(
            kind: .phoneCall,
            requiredPermission: .contactsRead,
            sensitivity: .outboundCommunication,
            defaultConfirmation: .systemUIHandoff,
            isUndoable: false,
            evidenceType: .systemShareOrDialHandoff,
            requiresUnlockedDevice: true
        ),
        .mapsDirections: ActionSpec(
            kind: .mapsDirections,
            requiredPermission: .none,
            sensitivity: .publicCommand,
            defaultConfirmation: .systemUIHandoff,
            isUndoable: false,
            evidenceType: .mapItemHandoff,
            requiresUnlockedDevice: false
        ),
        .shortcutsRun: ActionSpec(
            kind: .shortcutsRun,
            requiredPermission: .none,
            sensitivity: .externalBridge,
            defaultConfirmation: .shortcutPreview,
            isUndoable: false,
            evidenceType: .shortcutCallbackResult,
            requiresUnlockedDevice: true
        ),
        .textSummarizeAndNote: ActionSpec(
            kind: .textSummarizeAndNote,
            requiredPermission: .none,
            sensitivity: .personalWrite,
            defaultConfirmation: .undoableLocalWrite,
            isUndoable: true,
            evidenceType: .localNoteID,
            requiresUnlockedDevice: true
        ),
        .assistantReply: ActionSpec(
            kind: .assistantReply,
            requiredPermission: .none,
            sensitivity: .publicCommand,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .textOnlyResponse,
            requiresUnlockedDevice: false
        ),
        .briefingCompose: ActionSpec(
            kind: .briefingCompose,
            requiredPermission: .calendarRead,
            sensitivity: .personalRead,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .briefingSynthesisReport,
            requiresUnlockedDevice: true
        ),
        .remindersRead: ActionSpec(
            kind: .remindersRead,
            requiredPermission: .remindersFull,
            sensitivity: .personalRead,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .reminderIdentifierWithAlarm,
            requiresUnlockedDevice: true
        ),
        .mapsEstimateETA: ActionSpec(
            kind: .mapsEstimateETA,
            requiredPermission: .none,
            sensitivity: .publicCommand,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .etaCalculation,
            requiresUnlockedDevice: false
        ),
        .memoryRemember: ActionSpec(
            kind: .memoryRemember,
            requiredPermission: .none,
            sensitivity: .personalWrite,
            defaultConfirmation: .explicitSummary,
            isUndoable: true,
            evidenceType: .memoryVaultRecord,
            requiresUnlockedDevice: true
        ),
        .memoryRecall: ActionSpec(
            kind: .memoryRecall,
            requiredPermission: .none,
            sensitivity: .personalRead,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .memoryVaultRecord,
            requiresUnlockedDevice: true
        ),
        .memoryForget: ActionSpec(
            kind: .memoryForget,
            requiredPermission: .none,
            sensitivity: .personalWrite,
            defaultConfirmation: .explicitSummary,
            isUndoable: true,
            evidenceType: .memoryVaultRecord,
            requiresUnlockedDevice: true
        ),
        .alarmCreate: ActionSpec(
            kind: .alarmCreate,
            requiredPermission: .alarmKit,
            sensitivity: .personalWrite,
            defaultConfirmation: .explicitSummary,
            isUndoable: true,
            evidenceType: .alarmIdentifier,
            requiresUnlockedDevice: false
        )
    ]

    public static func spec(for kind: ActionKind) -> ActionSpec {
        if let existing = allSpecs[kind] {
            return existing
        }
        return ActionSpec(
            kind: kind,
            requiredPermission: .none,
            sensitivity: .publicCommand,
            defaultConfirmation: .none,
            isUndoable: false,
            evidenceType: .textOnlyResponse,
            requiresUnlockedDevice: false
        )
    }
}
