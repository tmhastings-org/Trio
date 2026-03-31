import Foundation

/// Internal utility for extracting structured values from OREF reason strings.
///
/// Reason strings are the primary source for fields not persisted to Core Data
/// (deviation, profileISF, TDD, AF, minPredBG, minGuardBG, dynamic ISF flags).
/// Centralised here so both the log parser and the Core Data bridge use identical logic.
internal enum ReasonStringParser {
    /// Extracts a decimal value that follows `prefix`, stopping at the first character
    /// in `terminator` (treated as a set of stop characters, not a literal string).
    static func extractDecimal(from reason: String, prefix: String, terminator: String) -> Decimal? {
        guard let r = reason.range(of: prefix) else { return nil }
        let remainder = String(reason[r.upperBound...])
        var numStr = ""
        for ch in remainder {
            if terminator.contains(ch) { break }
            if ch.isNumber || ch == "." || ch == "-" { numStr.append(ch) }
            else if !numStr.isEmpty { break }
        }
        return Decimal(string: numStr)
    }

    /// Extracts profile ISF and effective ISF from the "ISF: X→Y" pattern.
    /// Returns `(profileISF, effectiveISF)` — either may be nil if not present.
    static func extractISFFields(from reason: String) -> (profile: Decimal?, effective: Decimal?) {
        guard let match = reason.range(of: #"ISF: (\d+)→(\d+)"#, options: .regularExpression) else {
            return (nil, nil)
        }
        let substr = String(reason[match])
        let nums = substr.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        guard nums.count >= 2 else { return (nil, nil) }
        return (Decimal(string: nums[0]), Decimal(string: nums[1]))
    }

    /// Extracts deviation from "Dev: X" (supports negative values).
    static func extractDeviation(from reason: String) -> Decimal? {
        guard let match = reason.range(of: #"Dev: -?\d+"#, options: .regularExpression) else { return nil }
        let substr = String(reason[match])
        return Decimal(string: substr.replacingOccurrences(of: "Dev: ", with: ""))
    }

    /// Extracts minPredBG from "minPredBG X".
    static func extractMinPredBG(from reason: String) -> Decimal? {
        extractDecimal(from: reason, prefix: "minPredBG ", terminator: ", ;")
    }

    /// Extracts minGuardBG from "minGuardBG X".
    static func extractMinGuardBG(from reason: String) -> Decimal? {
        extractDecimal(from: reason, prefix: "minGuardBG ", terminator: ", ;")
    }

    /// Returns true when the reason string indicates Dynamic ISF was active this cycle.
    static func isDynamicISFActive(in reason: String) -> Bool {
        reason.contains("Dynamic ISF: On") || reason.contains("Sigmoid") || reason.contains("Logarithmic formula")
    }

    /// Extracts the dynamic sensitivity ratio from "Autosens ratio: X".
    static func extractDynamicRatio(from reason: String) -> Decimal? {
        extractDecimal(from: reason, prefix: "Autosens ratio: ", terminator: ", ;")
    }
}
