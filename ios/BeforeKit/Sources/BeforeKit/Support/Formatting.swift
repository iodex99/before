import Foundation

// =============================================================================
// BEFORE — formatting.
//
// Everything a user reads that contains a number or a date goes through here.
// No string concatenation that a translator cannot reorder, no hard-coded "$",
// no hard-coded date format (spec §62, §63).
// =============================================================================

public enum Formatting {
    /// A localised price, or nil when there is no price to show.
    ///
    /// Returns nil rather than "—" or "0" so the caller has to decide what an
    /// unknown price looks like in context; silently printing a zero is how a
    /// fabricated fact gets on screen.
    public static func price(
        _ amount: Double?,
        currencyCode: String?,
        locale: Locale = .current
    ) -> String? {
        guard let amount else { return nil }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        if let currencyCode, !currencyCode.isEmpty {
            formatter.currencyCode = currencyCode
        }
        // Whole amounts read better without ".00" on a shopping card, but a
        // price like 12.99 must keep its cents.
        let hasFraction = amount.truncatingRemainder(dividingBy: 1) != 0
        formatter.maximumFractionDigits = hasFraction ? 2 : 0
        formatter.minimumFractionDigits = hasFraction ? 2 : 0

        return formatter.string(from: NSNumber(value: amount))
    }

    /// A price for a total, always with its fraction digits.
    public static func total(
        _ amount: Double,
        currencyCode: String?,
        locale: Locale = .current
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        if let currencyCode, !currencyCode.isEmpty {
            formatter.currencyCode = currencyCode
        }
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    /// "Today", "Yesterday", or a short localised date.
    public static func relativeDay(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return NSLocalizedString("date.today", value: "Today", comment: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return NSLocalizedString("date.yesterday", value: "Yesterday", comment: "Yesterday")
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        // A localised template, never a literal format string.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    /// Section header for a day of history, e.g. "September 24".
    public static func sectionDate(
        _ date: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter.string(from: date)
    }

    /// Factor value as shown on the result screen: "8.5/10".
    public static func factorValue(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return "\(number)/10"
    }

    /// Bucketed score for analytics. Never the exact score (spec §44).
    public static func scoreBucket(_ score: Int) -> String {
        switch score {
        case ..<60: "0-59"
        case ..<80: "60-79"
        default: "80-100"
        }
    }
}

// =============================================================================
// Copy that depends on data the app may not have.
//
// Kept here rather than in a View so the "we don't know your wardrobe yet"
// path is testable — it is the single easiest place to accidentally imply
// knowledge BEFORE does not have (Rule 3, spec §93).
// =============================================================================

public enum ResultCopy {
    /// The line under the verdict.
    public static func basis(for analysis: Analysis) -> String {
        if analysis.lacksWardrobeContext {
            return "Based on your style and what you've told BEFORE so far."
        }
        return "Based on what you've told BEFORE about your style and what you already own."
    }

    /// Shown in place of a wardrobe claim when there is no wardrobe.
    public static let noWardrobeYet = "BEFORE doesn't know your wardrobe well enough yet."

    public static let noWardrobeHint =
        "Add a few pieces over time and BEFORE can make more personal calls."

    /// The practical next step, derived from the deterministic action — never
    /// free-form model text.
    public static func nextStep(for action: SuggestedAction) -> String {
        switch action {
        case .buyIt: "This one holds up. Go ahead."
        case .wait48Hours: "Wait 48 hours. If you're still thinking about it, come back."
        case .checkWardrobeFirst: "Check what you already own before you decide."
        case .waitForSale: "Worth waiting for a better price on this one."
        case .skipIt: "Skip it. You have better uses for the money."
        }
    }

    /// Shown when confidence is low, so a result is never presented as
    /// definitive when it isn't (spec §22).
    public static func confidenceNote(for label: ConfidenceLabel) -> String? {
        switch label {
        case .high, .medium: nil
        case .low: "Low confidence — BEFORE couldn't establish enough about this one."
        }
    }
}
