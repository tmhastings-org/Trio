import Foundation

// MARK: - Log Parser

protocol LogParser {
    func parse(logContents: [String]) -> [LoopCycleData]
}

struct TrioLogParser: LogParser {

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func parse(logContents: [String]) -> [LoopCycleData] {
        let allLines = logContents.flatMap { $0.components(separatedBy: "\n") }
        let determinations = extractDeterminations(from: allLines)
        let contexts = extractContexts(from: allLines)
        return mergeDeterminationsWithContext(determinations: determinations, contexts: contexts)
    }

    // MARK: - Determination Extraction

    private func extractDeterminations(from lines: [String]) -> [(Date, ParsedDetermination)] {
        var results: [(Date, ParsedDetermination)] = []
        var isAccumulating = false
        var jsonBuffer = ""
        var determinationTimestamp: Date?
        var braceDepth = 0

        for line in lines {
            if !isAccumulating {
                guard line.contains("OREF DETERMINATION:") else { continue }
                guard !line.contains("[SIMULATION]") else { continue }

                let lineTimestamp = extractTimestamp(from: line)
                guard let markerRange = line.range(of: "OREF DETERMINATION:") else { continue }
                let jsonStart = String(line[markerRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                jsonBuffer = jsonStart
                determinationTimestamp = lineTimestamp
                braceDepth = jsonStart.filter({ $0 == "{" }).count - jsonStart.filter({ $0 == "}" }).count
                isAccumulating = braceDepth > 0

                if braceDepth == 0 && !jsonBuffer.isEmpty {
                    if let det = parseDeterminationJSON(jsonBuffer), let ts = determinationTimestamp {
                        results.append((ts, det))
                    }
                    jsonBuffer = ""; determinationTimestamp = nil
                }
            } else {
                let content = stripLogPrefix(from: line)
                jsonBuffer += "\n" + content
                braceDepth += content.filter({ $0 == "{" }).count - content.filter({ $0 == "}" }).count

                if braceDepth <= 0 {
                    isAccumulating = false
                    if let det = parseDeterminationJSON(jsonBuffer), let ts = determinationTimestamp {
                        results.append((ts, det))
                    }
                    jsonBuffer = ""; determinationTimestamp = nil
                }
            }
        }

        return results
    }

    // MARK: - JSON Parsing with Reason-String Fallback

    private func parseDeterminationJSON(_ json: String) -> ParsedDetermination? {
        let cleaned = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let reason = raw["reason"] as? String ?? ""

        // Primary: from JSON fields
        var isf = decimal(raw["ISF"])
        var deviation = decimal(raw["deviation"])
        var profileISF: Decimal? = nil

        // Fallback: extract from reason string when JSON fields are missing
        // (e.g. v0.6.0.60 which omits ISF/deviation from the JSON)
        if isf == nil {
            let fields = ReasonStringParser.extractISFFields(from: reason)
            profileISF = fields.profile
            isf = fields.effective
        }
        if deviation == nil {
            deviation = ReasonStringParser.extractDeviation(from: reason)
        }

        // Extract AF, TDD, Basal ratio from reason for logarithmic analysis
        let reasonAF       = ReasonStringParser.extractDecimal(from: reason, prefix: "AF: ",         terminator: ",;)")
        let reasonTDD      = ReasonStringParser.extractDecimal(from: reason, prefix: "TDD: ",        terminator: " U")
        let reasonBasalRatio = ReasonStringParser.extractDecimal(from: reason, prefix: "Basal ratio: ", terminator: ",;)")

        let iobPredictions = (raw["predBGs"] as? [String: Any])?["IOB"] as? [Int]

        return ParsedDetermination(
            timestamp: parseDate(raw["deliverAt"]) ?? Date(),
            bg: decimal(raw["bg"]),
            isf: isf,
            profileISF: profileISF,
            sensitivityRatio: decimal(raw["sensitivityRatio"]),
            iob: decimal(raw["IOB"]),
            cob: decimal(raw["COB"]),
            deviation: deviation,
            insulinReq: decimal(raw["insulinReq"]),
            rate: decimal(raw["rate"]),
            units: decimal(raw["units"]),
            duration: decimal(raw["duration"]),
            eventualBG: raw["eventualBG"] as? Int,
            minPredBG: decimal(raw["minPredBG"]),
            minGuardBG: decimal(raw["minGuardBG"]),
            minDelta: decimal(raw["minDelta"]),
            expectedDelta: decimal(raw["expectedDelta"]),
            threshold: decimal(raw["threshold"]),
            carbRatio: decimal(raw["CR"]),
            reason: reason,
            reasonAF: reasonAF,
            reasonTDD: reasonTDD,
            reasonBasalRatio: reasonBasalRatio,
            iobPredictions: iobPredictions
        )
    }

    // MARK: - Context Extraction

    private func extractContexts(from lines: [String]) -> [ParsedLogContext] {
        var contextsByMinute: [String: ContextBuilder] = [:]

        for line in lines {
            guard let ts = extractTimestamp(from: line) else { continue }
            let key = minuteKey(ts)
            if contextsByMinute[key] == nil { contextsByMinute[key] = ContextBuilder(timestamp: ts) }
            let b = contextsByMinute[key]!

            if line.contains("UAM Impact:") {
                b.uamImpact = extractDecimal(from: line, after: "UAM Impact:", before: "mg/dL")
                b.uamDuration = extractDecimal(from: line, after: "UAM Duration:", before: "hours")
            }
            if line.contains("Dynamic autosens.ratio set to") {
                b.dynamicISFActive = true
                b.dynamicRatio = extractDecimal(from: line, after: "set to", before: "with")
            }
            if line.contains("Dynamic ISF limited by") { b.dynamicISFLimited = true }
            if line.contains("Override") && line.contains("active") {
                b.overrideActive = true
            }
            // Extract TDD: "Weighted TDD: X U" (dynamic ratios log) or "TDD: X U" (Nightscout upload reason)
            if line.contains("Weighted TDD:") {
                if b.tdd == nil { b.tdd = extractDecimal(from: line, after: "Weighted TDD:", before: "U") }
            } else if line.contains("TDD:") {
                if b.tdd == nil { b.tdd = extractDecimal(from: line, after: "TDD:", before: " U") }
            }

            contextsByMinute[key] = b
        }

        return contextsByMinute.values.map { $0.build() }
    }

    private func mergeDeterminationsWithContext(
        determinations: [(Date, ParsedDetermination)],
        contexts: [ParsedLogContext]
    ) -> [LoopCycleData] {
        let sorted = contexts.sorted { $0.timestamp < $1.timestamp }
        return determinations.map { (ts, det) in
            let nearest = sorted.min(by: { abs($0.timestamp.timeIntervalSince(ts)) < abs($1.timestamp.timeIntervalSince(ts)) })
            let matched = nearest.flatMap { abs($0.timestamp.timeIntervalSince(ts)) < 180 ? $0 : nil }
            return LoopCycleData(determination: det, context: matched)
        }
    }

    // MARK: - Utility

    private func extractTimestamp(from line: String) -> Date? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        return timestampFormatter.date(from: String(line[line.startIndex..<space]))
    }

    private func stripLogPrefix(from line: String) -> String {
        if let range = line.range(of: "DEV: ") { return String(line[range.upperBound...]) }
        return line
    }

    private func minuteKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(c.year!)-\(c.month!)-\(c.day!)-\(c.hour!)-\(c.minute!)"
    }

    private func extractDecimal(from line: String, after: String, before: String) -> Decimal? {
        guard let r = line.range(of: after) else { return nil }
        let remainder = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let value = remainder.components(separatedBy: before).first?.trimmingCharacters(in: .whitespaces)
            ?? remainder.components(separatedBy: .whitespaces).first ?? ""
        return Decimal(string: value)
    }

    private func decimal(_ value: Any?) -> Decimal? {
        if let n = value as? NSNumber { return n.decimalValue }
        if let d = value as? Double { return Decimal(d) }
        if let i = value as? Int { return Decimal(i) }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: str)
    }
}

private class ContextBuilder {
    let timestamp: Date
    var uamImpact: Decimal?
    var uamDuration: Decimal?
    var dynamicISFActive = false
    var dynamicRatio: Decimal?
    var dynamicISFLimited = false
    var overrideActive = false
    var overridePercentage: Decimal?
    var tempTargetActive = false

    var tdd: Decimal?

    init(timestamp: Date) { self.timestamp = timestamp }

    func build() -> ParsedLogContext {
        ParsedLogContext(timestamp: timestamp, uamImpact: uamImpact, uamDuration: uamDuration,
                         dynamicISFActive: dynamicISFActive, dynamicRatio: dynamicRatio,
                         dynamicISFLimited: dynamicISFLimited, overrideActive: overrideActive,
                         overridePercentage: overridePercentage, tempTargetActive: tempTargetActive,
                         tdd: tdd)
    }
}

// MARK: - Settings CSV Parser

protocol SettingsParser {
    func parse(csvContent: String) -> TrioSettingsProfile?
}

struct TrioSettingsCSVParser: SettingsParser {

    func parse(csvContent: String) -> TrioSettingsProfile? {
        let content = csvContent.hasPrefix("\u{FEFF}") ? String(csvContent.dropFirst()) : csvContent
        let rows = parseCSVRows(content)
        var lookup: [String: (value: String, unit: String)] = [:]

        for row in rows {
            guard row.count >= 5 else { continue }
            let key = "\(row[0].trimmed)|\(row[1].trimmed)|\(row[2].trimmed)"
            lookup[key] = (value: row[3].trimmed, unit: row[4].trimmed)
        }

        func find(_ name: String, cat: String? = nil, sub: String? = nil) -> String? {
            for (key, val) in lookup {
                let p = key.components(separatedBy: "|")
                guard p.count == 3, p[2].localizedCaseInsensitiveContains(name) else { continue }
                if let c = cat, !p[0].localizedCaseInsensitiveContains(c) { continue }
                if let s = sub, !p[1].localizedCaseInsensitiveContains(s) { continue }
                return val.value
            }
            return nil
        }

        func findDec(_ name: String, cat: String? = nil, sub: String? = nil) -> Decimal? {
            guard let s = find(name, cat: cat, sub: sub) else { return nil }
            return Decimal(string: s)
        }

        func findBool(_ name: String, cat: String? = nil, sub: String? = nil) -> Bool {
            (find(name, cat: cat, sub: sub) ?? "").localizedCaseInsensitiveContains("enabled")
        }

        func findSchedule(_ subcategory: String) -> [ScheduleEntry] {
            var entries: [ScheduleEntry] = []
            for (key, val) in lookup {
                let p = key.split(separator: "|").map(String.init)
                guard p.count == 3, p[0] == "Therapy" || p[0].contains("Therapy") else { continue }
                guard p[1].localizedCaseInsensitiveContains(subcategory) else { continue }
                // Filter out Override Presets (they have percentage values)
                if val.value.contains("%") { continue }
                if let timeRange = p[2].range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) {
                    let time = String(p[2][timeRange])
                    let parts = time.split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2, let value = Decimal(string: val.value) {
                        // Handle AM/PM if present
                        var hour = parts[0]
                        if p[2].contains("PM") && hour != 12 { hour += 12 }
                        if p[2].contains("AM") && hour == 12 { hour = 0 }
                        entries.append(ScheduleEntry(time: time, offsetMinutes: hour * 60 + parts[1], value: value))
                    }
                }
            }
            return entries.sorted { $0.offsetMinutes < $1.offsetMinutes }
        }

        let dsfValue = find("Dynamic ISF", sub: "Dynamic") ?? "Disabled"
        let dynamicISFMode: DynamicISFMode
        if dsfValue.localizedCaseInsensitiveContains("Sigmoid") { dynamicISFMode = .sigmoid }
        else if dsfValue.localizedCaseInsensitiveContains("Logarithmic") { dynamicISFMode = .logarithmic }
        else { dynamicISFMode = .disabled }

        let unitsStr = find("Glucose Units") ?? "mg/dL"
        let glucoseUnits: GlucoseUnit = unitsStr.contains("mmol") ? .mmolL : .mgdL

        let insulinName: String? = find("Insulin Type", cat: "Device")
        let curveStr = insulinName ?? "rapid-acting"
        let insulinCurve: InsulinCurveType
        if curveStr.localizedCaseInsensitiveContains("ultra") { insulinCurve = .ultraRapid }
        else if curveStr.localizedCaseInsensitiveContains("bilinear") { insulinCurve = .bilinear }
        else { insulinCurve = .rapidActing }

        let asMax = (findDec("Autosens Max", sub: "Autosens") ?? 120) / 100
        let asMin = (findDec("Autosens Min", sub: "Autosens") ?? 70) / 100
        let af = (findDec("Adjustment Factor", sub: "Dynamic") ?? 80) / 100
        let afSig = (findDec("Sigmoid Adjustment", sub: "Dynamic") ?? 50) / 100
        let weight = (findDec("Weighted Average of TDD", sub: "Dynamic") ?? 35) / 100

        return TrioSettingsProfile(
            exportDate: nil,
            appVersion: find("App Version", cat: "Metadata"),
            glucoseUnits: glucoseUnits,
            basalRates: findSchedule("Basal Rate"),
            isfSchedule: findSchedule("Insulin Sensitivit"),
            crSchedule: findSchedule("Carb Ratio"),
            glucoseTargets: findSchedule("Glucose Target"),
            maxIOB: findDec("Maximum Insulin on Board") ?? 0,
            maxBolus: findDec("Maximum Bolus") ?? 0,
            maxBasalRate: findDec("Maximum Basal Rate") ?? 0,
            maxCOB: findDec("Maximum Carbs on Board") ?? 120,
            threshold: findDec("Minimum Safety Threshold") ?? 60,
            insulinCurve: insulinCurve,
            insulinName: insulinName,
            dia: findDec("Duration of Insulin Action") ?? 9,
            useCustomPeakTime: findBool("Use Custom Peak Time"),
            insulinPeakTime: findDec("Insulin Peak Time") ?? 75,
            autosensMax: asMax, autosensMin: asMin,
            dynamicISFMode: dynamicISFMode,
            adjustmentFactor: af, adjustmentFactorSigmoid: afSig,
            weightPercentage: weight,
            tddAdjustBasal: findBool("Adjust Basal", sub: "Dynamic"),
            enableSMBAlways: findBool("Enable SMB Always"),
            enableSMBWithCOB: findBool("Enable SMB With COB"),
            enableSMBWithTemptarget: findBool("Enable SMB With Temptarget"),
            enableSMBAfterCarbs: findBool("Enable SMB After Carbs"),
            enableSMBHighBG: findBool("Enable SMB With High Glucose"),
            enableSMBHighBGTarget: findDec("High Glucose Target", sub: "SMB") ?? 110,
            enableUAM: findBool("Enable UAM"),
            maxSMBBasalMinutes: findDec("Max SMB Basal Minutes") ?? 30,
            maxUAMSMBBasalMinutes: findDec("Max UAM Basal Minutes") ?? 30,
            smbDeliveryRatio: (findDec("SMB Delivery Ratio") ?? 50) / 100,
            maxDeltaBGThreshold: (findDec("Max Allowed Glucose Rise for SMB") ?? 20) / 100,
            highTemptargetRaisesSensitivity: findBool("High Temptarget Raises"),
            lowTemptargetLowersSensitivity: findBool("Low Temptarget Lowers"),
            sensitivityRaisesTarget: findBool("Sensitivity Raises Target"),
            resistanceLowersTarget: findBool("Resistance Lowers Target"),
            halfBasalExerciseTarget: findDec("Half Basal Exercise Target") ?? 160,
            useFPUConversion: findBool("FPU"),
            individualAdjustmentFactor: (findDec("Individual Adjustment Factor") ?? 50) / 100,
            fpuDelay: findDec("Delay", cat: "Feature") ?? 60,
            fpuInterval: findDec("Interval", cat: "Feature") ?? 30,
            smoothGlucose: findBool("Smooth Glucose")
        )
    }

    private func parseCSVRows(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false

        for (i, line) in content.components(separatedBy: .newlines).enumerated() {
            if i == 0 && line.contains("Setting Category") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            for ch in line {
                if ch == "\"" { inQuotes.toggle() }
                else if ch == "," && !inQuotes { currentRow.append(field); field = "" }
                else { field.append(ch) }
            }

            if !inQuotes {
                currentRow.append(field); field = ""
                rows.append(currentRow); currentRow = []
            } else { field.append("\n") }
        }
        return rows
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
