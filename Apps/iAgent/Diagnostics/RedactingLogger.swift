import Foundation
import os
import AgentCore

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
        guard !raw.isEmpty else { return raw }

        // 1. URL sorgu parametrelerindeki anahtar/jeton değerlerini (?key=..., &token=...) maskele.
        var sanitized = replacing(
            in: raw,
            pattern: #"([?&](?:key|api[_-]?key|apikey|token|access[_-]?token|refresh[_-]?token|id[_-]?token|secret|password|auth|sig|signature)=)([^&#\s]+)"#,
            options: [.caseInsensitive],
            template: "$1[REDACTED]"
        )

        // 2. AgentCore.MemorySecretGuard ile API anahtarları, Bearer, JWT, TR/AZ IBAN, TCKN, kart PAN ve parolaları maskele.
        sanitized = MemorySecretGuard.redactSecrets(in: sanitized)

        // 3. Ek desenler: kısa parçalı JWT, genel IBAN, bitişik PAN, TCKN, sk-/Bearer, e-posta ve telefon numaraları.
        let patterns: [(pattern: String, options: NSRegularExpression.Options, replacement: String)] = [
            (#"\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}(?:\.[A-Za-z0-9_\-]{4,})?\b"#, [], "[JWT_REDACTED]"),
            (#"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]){11,28}\b"#, [], "[IBAN_REDACTED]"),
            (#"(?<![+\d])\b\d{13,19}\b"#, [], "[PAN_REDACTED]"),
            (#"\b(?:tckn|tc\s*kimlik(?:\s*no)?|kimlik\s*no)\s*[:=\-]?\s*[1-9]\d{10}\b"#, [.caseInsensitive], "[TCKN_REDACTED]"),
            (#"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#, [.caseInsensitive], "Bearer [REDACTED]"),
            (#"sk-[A-Za-z0-9\-_]{6,}"#, [.caseInsensitive], "sk-[REDACTED]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, [.caseInsensitive], "[EMAIL_REDACTED]"),
            (#"\+?\d[\d\s\-]{7,}\d"#, [], "[PHONE_REDACTED]")
        ]

        for item in patterns {
            sanitized = replacing(in: sanitized, pattern: item.pattern, options: item.options, template: item.replacement)
        }
        return sanitized
    }

    private static func replacing(
        in input: String,
        pattern: String,
        options: NSRegularExpression.Options,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
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
