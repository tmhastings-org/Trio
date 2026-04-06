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

        let blocksWithData = timeBlocks.filter { $0.cleanDataPoints >= AnalysisThresholds.minimumDataPointsPerBlock }

        let maxMedianDev = blocksWithData.map { abs($0.medianDeviation) }.max() ?? 0
        let deviationSignal = maxMedianDev > AnalysisThresholds.basalDeviationMagnitude

        // Secondary signal: sustained autosens ratio bias.
        // Only valid for static ISF (Dynamic ISF disabled). In logarithmic and sigmoid modes,
        // sensitivityRatio is formula-driven (TDD × AF × current BG), not a reflection of
        // accumulated deviation-based autosensitivity. A ratio bias in those modes indicates
        // the formula's output at typical BG levels — not that autosens is compensating for
        // a basal problem. For Dynamic ISF users, deviation-based analysis is the only valid signal.
        let ratioBiasBlocks = blocksWithData.filter {
            abs(NSDecimalNumber(decimal: $0.medianSensitivityRatio).doubleValue - 1.0) >= 0.05
        }
        let ratioDirection: Int? = {
            guard settings.dynamicISFMode == .disabled else { return nil }
            guard ratioBiasBlocks.count >= max(1, blocksWithData.count / 2) else { return nil }
            let above = ratioBiasBlocks.filter { $0.medianSensitivityRatio > 1 }.count
            let below = ratioBiasBlocks.filter { $0.medianSensitivityRatio < 1 }.count
            if above > below { return 1 }   // basal too low — autosens running high
            if below > above { return -1 }  // basal too high — autosens running low
            return nil  // mixed signal — not actionable
        }()
        let ratioSignal = ratioDirection != nil

        // Apply ratio-based suggested values to blocks that have the bias but quiet deviation
        let timeBlocksWithRatioSuggestions: [TimeBlockAnalysis] = timeBlocks.map { block in
            guard block.suggestedValue == nil,  // deviation didn't already produce a suggestion
                  block.cleanDataPoints >= AnalysisThresholds.minimumDataPointsPerBlock,
                  let dir = ratioDirection
            else { return block }

            let ratio = NSDecimalNumber(decimal: block.medianSensitivityRatio).doubleValue
            guard abs(ratio - 1.0) >= 0.05 else { return block }

            // 50% step toward the ratio-implied basal (static ISF only).
            // Ratio bias is a directional signal — the deviation stays quiet because autosens
            // is absorbing the offset. 50% is conservative but large enough to survive rounding.
            let implied = block.currentProfileValue * block.medianSensitivityRatio
            let conservative = block.currentProfileValue + (implied - block.currentProfileValue) * Decimal(0.5)
            let suggested = roundBasal(conservative)
            guard suggested != block.currentProfileValue else { return block }
            let adjPct = ((suggested - block.currentProfileValue) / block.currentProfileValue) * 100
            _ = dir  // direction already validated above

            return TimeBlockAnalysis(
                blockLabel: block.blockLabel,
                startMinutes: block.startMinutes, endMinutes: block.endMinutes,
                cleanDataPoints: block.cleanDataPoints, totalDataPoints: block.totalDataPoints,
                medianDeviation: block.medianDeviation, meanDeviation: block.meanDeviation,
                deviationP25: block.deviationP25, deviationP75: block.deviationP75,
                medianSensitivityRatio: block.medianSensitivityRatio,
                sensitivityRatioAtMax: block.sensitivityRatioAtMax,
                sensitivityRatioAtMin: block.sensitivityRatioAtMin,
                currentProfileValue: block.currentProfileValue,
                suggestedValue: suggested, adjustmentPercent: adjPct
            )
        }

        let needsAdjustment = deviationSignal || ratioSignal

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

        let score = ratioSignal
            ? blocksWithData.map { abs(NSDecimalNumber(decimal: $0.medianSensitivityRatio).doubleValue - 1.0) }.max().map { Decimal($0 * 100) } ?? maxMedianDev
            : maxMedianDev

        return SettingScore(setting: .basal, score: score, needsAdjustment: needsAdjustment,
                            confidence: confidence, limitHitPercentage: 0,
                            cleanDataPointsTotal: clean.count,
                            timeBlockAnalyses: timeBlocksWithRatioSuggestions)
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

    private func roundBasal(_ value: Decimal) -> Decimal {
        var result = Decimal()
        var mutable = value * 20
        NSDecimalRound(&result, &mutable, 0, .plain)
        return result / 20  // 0.05 U/hr increments
    }

    private func emptyBlock(label: String, start: Int, end: Int, total: Int, profile: Decimal) -> TimeBlockAnalysis {
        TimeBlockAnalysis(blockLabel: label, startMinutes: start, endMinutes: end,
                          cleanDataPoints: 0, totalDataPoints: total,
                          medianDeviation: 0, meanDeviation: 0, deviationP25: 0, deviationP75: 0,
                          medianSensitivityRatio: 1, sensitivityRatioAtMax: 0, sensitivityRatioAtMin: 0,
                          currentProfileValue: profile, suggestedValue: nil, adjustmentPercent: nil)
    }
}
