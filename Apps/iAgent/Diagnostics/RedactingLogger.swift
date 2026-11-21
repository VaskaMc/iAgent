import Foundation
import os

public enum DiagnosticCategory: String, Sendable {
    case lifecycle
    case intent
    case modelRouter
    case execution
    case privacy
}

/// Üretim günlüklerinde tam komut metni, kişi adı, not içeriği, ham ses veya API anahtarı bulunmaz.
/// Yalnızca görev kimliği, eylem türü, durum kodu ve maskelenmiş özet yazar.
public struct RedactingLogger: Sendable {
    private static let logger = Logger(subsystem: "com.iagent.app", category: "diagnostics")

    public init() {}

    public static func redact(_ raw: String) -> String {
        var sanitized = raw
        let patterns: [(String, String)] = [
            (#"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#, "Bearer [REDACTED]"),
            (#"sk-[A-Za-z0-9\-_]{6,}"#, "sk-[REDACTED]"),
            (#"\+?\d[\d\s\-]{7,}\d"#, "[PHONE_REDACTED]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[EMAIL_REDACTED]")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(sanitized.startIndex..., in: sanitized)
                sanitized = regex.stringByReplacingMatches(in: sanitized, range: range, withTemplate: replacement)
            }
        }
        return sanitized
    }

    public func logEvent(
        category: DiagnosticCategory,
        taskId: UUID,
        action: String,
        status: String,
        rawSensitiveDetail: String? = nil
    ) -> String {
        let safeDetail = rawSensitiveDetail.map { Self.redact("len=\($0.count)") } ?? "none"
        let line = "[\(category.rawValue)] task=\(taskId.uuidString.prefix(8)) action=\(action) status=\(status) detail=\(safeDetail)"
        Self.logger.info("\(line, privacy: .public)")
        return line
    }
}
