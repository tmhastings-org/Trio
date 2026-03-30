import Foundation

protocol BasalAnalyzer {
    func analyze(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore
}

struct TrioBasalAnalyzer: BasalAnalyzer {

    func analyze(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore {
        let clean = classified.filter { $0.isCleanForBasal }

        guard clean.count >= AnalysisThresholds.minimumTotalDataPoints else {
            return SettingScore(setting: .basal, score: 0, needsAdjustment: false,
                                confidence: .insufficient, limitHitPercentage: 0,
                                cleanDataPointsTotal: clean.count, timeBlockAnalyses: [])
        }

        let hourlyGroups = groupByHour(clean)
        let timeBlocks = buildTimeBlocks(hourlyGroups: hourlyGroups, basalSchedule: settings.basalRates,
                                          allClassified: classified, settings: settings)

        let maxMedianDev = timeBlocks
            .filter { $0.cleanDataPoints >= AnalysisThresholds.minimumDataPointsPerBlock }
            .map { abs($0.medianDeviation) }
            .max() ?? 0

        let needsAdjustment = maxMedianDev > AnalysisThresholds.basalDeviationMagnitude

        let blocksWithData = timeBlocks.filter { $0.cleanDataPoints >= AnalysisThresholds.minimumDataPointsPerBlock }
        let confidence: ConfidenceLevel
        if clean.count >= AnalysisThresholds.minimumTotalDataPoints * 3 && blocksWithData.count >= timeBlocks.count / 2 {
            confidence = .high
        } else if clean.count >= AnalysisThresholds.minimumTotalDataPoints && blocksWithData.count >= 2 {
            confidence = .moderate
        } else if clean.count >= AnalysisThresholds.minimumDataPointsPerBlock {
            confidence = .low
        } else {
            confidence = .insufficient
        }

        return SettingScore(setting: .basal, score: maxMedianDev, needsAdjustment: needsAdjustment,
                            confidence: confidence, limitHitPercentage: 0,
                            cleanDataPointsTotal: clean.count, timeBlockAnalyses: timeBlocks)
    }

    private func groupByHour(_ cycles: [WindowClassification]) -> [Int: [WindowClassification]] {
        var groups: [Int: [WindowClassification]] = [:]
        for c in cycles {
            let hour = Calendar.current.component(.hour, from: c.cycle.determination.timestamp)
            groups[hour, default: []].append(c)
        }
        return groups
    }

    private func buildTimeBlocks(
        hourlyGroups: [Int: [WindowClassification]],
        basalSchedule: [ScheduleEntry],
        allClassified: [WindowClassification],
        settings: TrioSettingsProfile
    ) -> [TimeBlockAnalysis] {
        guard !basalSchedule.isEmpty else { return [] }
        let boundaries = basalSchedule.map { $0.offsetMinutes / 60 }
        var blocks: [TimeBlockAnalysis] = []

        for (i, startHour) in boundaries.enumerated() {
            let endHour = i + 1 < boundaries.count ? boundaries[i + 1] : 24
            let basalRate = basalSchedule[i].value

            var blockCycles: [WindowClassification] = []
            var totalInBlock = 0
            for hour in startHour..<endHour {
                let h = hour % 24
                blockCycles.append(contentsOf: hourlyGroups[h] ?? [])
                totalInBlock += allClassified.filter {
                    Calendar.current.component(.hour, from: $0.cycle.determination.timestamp) == h
                }.count
            }

            let devs = blockCycles.compactMap { $0.cycle.determination.deviation }
                .map { NSDecimalNumber(decimal: $0).doubleValue }.sorted()

            let label = formatLabel(startHour: startHour, endHour: endHour)

            guard !devs.isEmpty else {
                blocks.append(emptyBlock(label: label, start: startHour * 60, end: endHour * 60,
                                          total: totalInBlock, profile: basalRate))
                continue
            }

            let median = Decimal(percentile(devs, p: 0.50))
            let mean = Decimal(devs.reduce(0, +) / Double(devs.count))
            let p25 = Decimal(percentile(devs, p: 0.25))
            let p75 = Decimal(percentile(devs, p: 0.75))

            let ratios = blockCycles.compactMap { $0.cycle.determination.sensitivityRatio }
            let medianRatio = ratios.isEmpty ? Decimal(1) : sortedMedian(ratios)
            let atMax = ratios.filter { $0 >= settings.autosensMax - 0.01 }.count
            let atMin = ratios.filter { $0 <= settings.autosensMin + 0.01 }.count

            let isfForBlock = effectiveISF(hour: startHour, settings: settings)
            let (suggested, adjPct) = computeAdjustment(current: basalRate, medianDev: median,
                                                         isf: isfForBlock, n: devs.count)

            blocks.append(TimeBlockAnalysis(
                blockLabel: label, startMinutes: startHour * 60, endMinutes: endHour * 60,
                cleanDataPoints: devs.count, totalDataPoints: totalInBlock,
                medianDeviation: median, meanDeviation: mean, deviationP25: p25, deviationP75: p75,
                medianSensitivityRatio: medianRatio, sensitivityRatioAtMax: atMax, sensitivityRatioAtMin: atMin,
                currentProfileValue: basalRate, suggestedValue: suggested, adjustmentPercent: adjPct
            ))
        }
        return blocks
    }

    private func computeAdjustment(current: Decimal, medianDev: Decimal, isf: Decimal, n: Int)
        -> (Decimal?, Decimal?) {
        guard n >= AnalysisThresholds.minimumDataPointsPerBlock,
              abs(medianDev) > AnalysisThresholds.basalDeviationMagnitude,
              isf > 0, current > 0 else { return (nil, nil) }

        let basalDelta = (medianDev / isf) * 2
        let conservative = basalDelta * Decimal(0.2)
        let suggested = max(Decimal(0.05), current + conservative)
        let adjPct = (conservative / current) * 100
        return (suggested, adjPct)
    }

    private func effectiveISF(hour: Int, settings: TrioSettingsProfile) -> Decimal {
        let mins = hour * 60
        var isf = settings.isfSchedule.last?.value ?? 50
        for e in settings.isfSchedule { if e.offsetMinutes <= mins { isf = e.value } else { break } }
        // Deviations in the logs are always in mg/dL (Trio's internal unit).
        // If the user's ISF schedule is in mmol/L, convert to mg/dL before applying the formula.
        return settings.glucoseUnits == .mmolL ? isf * 18 : isf
    }

    private func formatLabel(startHour: Int, endHour: Int) -> String {
        func fmt(_ h: Int) -> String {
            let n = h % 24
            if n == 0 { return "12:00 AM" }; if n == 12 { return "12:00 PM" }
            return n < 12 ? "\(n):00 AM" : "\(n-12):00 PM"
        }
        return "\(fmt(startHour)) – \(fmt(endHour))"
    }

    private func percentile(_ sorted: [Double], p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let idx = p * Double(sorted.count - 1)
        let lo = Int(idx); let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (idx - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    private func sortedMedian(_ values: [Decimal]) -> Decimal {
        let s = values.sorted(); let m = s.count / 2
        return s.count % 2 == 0 ? (s[m-1] + s[m]) / 2 : s[m]
    }

    private func emptyBlock(label: String, start: Int, end: Int, total: Int, profile: Decimal) -> TimeBlockAnalysis {
        TimeBlockAnalysis(blockLabel: label, startMinutes: start, endMinutes: end,
                          cleanDataPoints: 0, totalDataPoints: total,
                          medianDeviation: 0, meanDeviation: 0, deviationP25: 0, deviationP75: 0,
                          medianSensitivityRatio: 1, sensitivityRatioAtMax: 0, sensitivityRatioAtMin: 0,
                          currentProfileValue: profile, suggestedValue: nil, adjustmentPercent: nil)
    }
}
