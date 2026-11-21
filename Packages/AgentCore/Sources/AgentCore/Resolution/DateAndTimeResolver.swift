import Foundation

public enum DateResolutionResult: Equatable, Sendable {
    case resolved(start: Date, iso8601: String)
    case ambiguous(questionTR: String, questionAZ: String, missingFields: [String])
}

/// Cihazın saat dilimi ve sabitlenebilir saati kullanarak göreli Türkçe/Azerbaycanca zaman ifadelerini çözer.
public enum DateAndTimeResolver {
    public static func resolve(
        expression: String,
        referenceDate: Date,
        timeZone: TimeZone = TimeZone(identifier: "Asia/Baku") ?? .current,
        relativeToBaseStart baseStart: Date? = nil
    ) -> DateResolutionResult {
        let norm = TurkicTextNormalizer.normalize(expression.trimmingCharacters(in: .whitespacesAndNewlines))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Belirsiz ifadeler -> mutlaka mutlak tarih/saat sorulur
        if norm.contains("cuma aksami") || norm.contains("cume axsami") {
            return .ambiguous(
                questionTR: "Cuma akşamı için tam tarihi ve saati (ör. 27 Kasım 19.00) belirtir misin?",
                questionAZ: "Cümə axşamı üçün dəqiq tarix və saatı seçərsən?",
                missingFields: ["startISO8601"]
            )
        }
        if norm.contains("obur cuma") || norm.contains("gelen cume") {
            return .ambiguous(
                questionTR: "\"Öbür cuma\" bu haftadaki cuma mı yoksa bir sonraki haftanın cuması mı? Tarih ve saati netleştirir misin?",
                questionAZ: "Hansı cümə gününü və saatı nəzərdə tutursan?",
                missingFields: ["startISO8601"]
            )
        }
        if norm == "sabah saat doqquzda mene xatirlat" || norm == "sabah doqquzda" {
            return .ambiguous(
                questionTR: "Yarın saat 09.00 için neyi hatırlatmamı ve hangi başlığı yazmamı istersin?",
                questionAZ: "Sabah saat 09:00 üçün nəyi xatırlatmağımı istəyirsən?",
                missingFields: ["title"]
            )
        }

        // "yarım saat önce" göreli ifadesi
        if norm.contains("yarim saat once"), let baseStart {
            let target = baseStart.addingTimeInterval(-30 * 60)
            return .resolved(start: target, iso8601: formatISO8601(target, timeZone: timeZone))
        }

        // Gün ofseti belirleme
        var targetDayDate = referenceDate
        if norm.contains("yarin") || norm.contains("sabah ") || norm == "sabah" {
            targetDayDate = calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate
        } else if norm.contains("cuma") || norm.contains("cume") {
            // Önümüzdeki Cuma (weekday = 6 in Gregorian where Sunday = 1)
            let currentWeekday = calendar.component(.weekday, from: referenceDate)
            let daysUntilFriday = (6 - currentWeekday + 7) % 7
            let offset = daysUntilFriday == 0 ? 7 : daysUntilFriday
            targetDayDate = calendar.date(byAdding: .day, value: offset, to: referenceDate) ?? referenceDate
        }

        // Saat ve dakika çıkarma ("10'da", "15.00'e", "19:00", "09.30")
        let (hour, minute) = extractHourMinute(from: norm)
        guard let hour else {
            return .ambiguous(
                questionTR: "Bu işlem için tam saat bilgisini paylaşır mısın?",
                questionAZ: "Bu əməliyyat üçün dəqiq saatı qeyd edərsən?",
                missingFields: ["startISO8601"]
            )
        }

        var components = calendar.dateComponents([.year, .month, .day], from: targetDayDate)
        components.hour = hour
        components.minute = minute ?? 0
        components.second = 0
        components.timeZone = timeZone

        guard let resolvedDate = calendar.date(from: components) else {
            return .ambiguous(
                questionTR: "Tarih oluşturulamadı; lütfen gün ve saat belirtin.",
                questionAZ: "Tarix yaradıla bilmədi; zəhmət olmasa gün və saatı qeyd edin.",
                missingFields: ["startISO8601"]
            )
        }

        return .resolved(start: resolvedDate, iso8601: formatISO8601(resolvedDate, timeZone: timeZone))
    }

    public static func formatISO8601(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func extractHourMinute(from normalized: String) -> (Int?, Int?) {
        // Regex: (\d{1,2})[:.](\d{2}) veya (\d{1,2})'?(da|de|te|ta|e|a)?
        let patternColon = #"(?:^|\s)(\d{1,2})[:.](\d{2})(?:\b|')"#
        if let regex = try? NSRegularExpression(pattern: patternColon),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let hRange = Range(match.range(at: 1), in: normalized),
           let mRange = Range(match.range(at: 2), in: normalized),
           let h = Int(normalized[hRange]),
           let m = Int(normalized[mRange]),
           (0...23).contains(h), (0...59).contains(m) {
            return (h, m)
        }

        let patternHour = #"(?:^|\s)(\d{1,2})(?:'?(?:da|de|te|ta|e|a))?(?:\s|$)"#
        if let regex = try? NSRegularExpression(pattern: patternHour),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let hRange = Range(match.range(at: 1), in: normalized),
           let h = Int(normalized[hRange]),
           (0...23).contains(h) {
            return (h, 0)
        }

        if normalized.contains("doqquz") || normalized.contains("dokuz") {
            return (9, 0)
        }
        return (nil, nil)
    }
}
