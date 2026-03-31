import Foundation

protocol MealEventDetector {
    func detect(cycles: [LoopCycleData], settings: TrioSettingsProfile, userType: DetectedUserType) -> [MealEvent]
}

protocol CRAnalyzer {
    func analyze(
        classified: [WindowClassification],
        mealEvents: [MealEvent],
        settings: TrioSettingsProfile,
        carbCountingConfidence: CarbCountingConfidence
    ) -> SettingScore
}

// MARK: - Meal Event Detector

struct TrioMealEventDetector: MealEventDetector {
    func detect(cycles: [LoopCycleData], settings: TrioSettingsProfile, userType _: DetectedUserType) -> [MealEvent] {
        var events: [MealEvent] = []
        var startIdx: Int?
        var peak: Decimal = 0
        var cobDepleted = false

        for (i, cycle) in cycles.enumerated() {
            let cob = cycle.determination.cob ?? 0
            if cob > 0, startIdx == nil {
                startIdx = i
                peak = cob
                cobDepleted = false
            } else if cob > 0, startIdx != nil {
                peak = max(peak, cob)
            } else if cob == 0, let si = startIdx {
                if !cobDepleted {
                    cobDepleted = true
                    let ahead = min(i + 6, cycles.count)
                    if (i + 1 ..< ahead).contains(where: { (cycles[$0].determination.cob ?? 0) > 0 }) { continue }
                }
                let basal = basalRate(cycle.determination.timestamp, settings.basalRates) ?? Decimal(0.5)
                let siIOB = cycles[si].determination.iob ?? 0
                let curIOB = cycle.determination.iob ?? 0
                if curIOB <= siIOB + basal / 2 || i == cycles.count - 1 {
                    if let event = buildEvent(cycles, si, i, peak, settings) { events.append(event) }
                    startIdx = nil
                    peak = 0
                    cobDepleted = false
                }
            }
        }
        return events
    }

    private func buildEvent(
        _ cycles: [LoopCycleData],
        _ si: Int,
        _ ei: Int,
        _ peak: Decimal,
        _ settings: TrioSettingsProfile
    ) -> MealEvent? {
        guard si < ei, ei < cycles.count else { return nil }
        let s = cycles[si].determination
        let e = cycles[ei].determination
        guard let sBG = s.bg, let eBG = e.bg else { return nil }

        var insulin: Decimal = 0
        for idx in si ... ei {
            let d = cycles[idx].determination
            if let u = d.units, u > 0 { insulin += u }
            if let r = d.rate, let dur = d.duration, dur > 0 {
                let sched = basalRate(d.timestamp, settings.basalRates) ?? 0
                insulin += (r - sched) * min(Decimal(NSDecimalNumber(decimal: dur).doubleValue), 5) / 60
            }
        }

        var hasFPU = false
        var wasZero = false
        for idx in si ... ei {
            let c = cycles[idx].determination.cob ?? 0
            if c == 0, !wasZero { wasZero = true }
            else if c > 0, wasZero { hasFPU = true
                break }
        }

        let isf = effectiveISF(e.timestamp, settings)
        guard isf > 0 else { return nil }
        let bgCorr = (eBG - sBG) / isf
        let totalNeeded = insulin + (s.iob ?? 0) + bgCorr
        let effCR = totalNeeded > 0 ? peak / totalNeeded : nil

        return MealEvent(
            mealStartTime: s.timestamp,
            mealEndTime: e.timestamp,
            startBG: sBG,
            endBG: eBG,
            startIOB: s.iob ?? 0,
            endIOB: e.iob ?? 0,
            carbsEntered: peak,
            totalInsulinDelivered: insulin,
            effectiveCR: effCR,
            hasFPUTail: hasFPU
        )
    }

    private func basalRate(_ date: Date, _ schedule: [ScheduleEntry]) -> Decimal? {
        guard !schedule.isEmpty else { return nil }
        let m = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        var r = schedule.last!.value
        for e in schedule { if e.offsetMinutes <= m { r = e.value } else { break } }
        return r
    }

    private func effectiveISF(_ date: Date, _ settings: TrioSettingsProfile) -> Decimal {
        let m = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        var isf = settings.isfSchedule.last?.value ?? 50
        for e in settings.isfSchedule { if e.offsetMinutes <= m { isf = e.value } else { break } }
        return isf
    }
}

// MARK: - CR Analyzer

struct TrioCRAnalyzer: CRAnalyzer {
    func analyze(
        classified _: [WindowClassification],
        mealEvents: [MealEvent],
        settings: TrioSettingsProfile,
        carbCountingConfidence: CarbCountingConfidence
    ) -> SettingScore {
        let valid = mealEvents.filter { $0.carbsEntered > 0 && ($0.effectiveCR ?? 0) > 0
            && $0.mealEndTime.timeIntervalSince($0.mealStartTime) > 3600 }

        guard valid.count >= AnalysisThresholds.minimumMealEvents else {
            return SettingScore(
                setting: .cr,
                score: 0,
                needsAdjustment: false,
                confidence: .insufficient,
                limitHitPercentage: 0,
                cleanDataPointsTotal: valid.count,
                timeBlockAnalyses: []
            )
        }

        let clean = valid.filter { !$0.hasFPUTail }
        let pool = clean.count >= AnalysisThresholds.minimumMealEvents ? clean : valid
        let crs = pool.compactMap(\.effectiveCR).sorted()
        guard !crs.isEmpty else {
            return SettingScore(
                setting: .cr,
                score: 0,
                needsAdjustment: false,
                confidence: .insufficient,
                limitHitPercentage: 0,
                cleanDataPointsTotal: 0,
                timeBlockAnalyses: []
            )
        }

        let medianCR = sortedMedian(crs)
        let profileCR = settings.crSchedule.first?.value ?? 10

        let doubles = crs.map { NSDecimalNumber(decimal: $0).doubleValue }
        let mean = doubles.reduce(0, +) / Double(doubles.count)
        let sd = sqrt(doubles.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(doubles.count))
        let cv = mean > 0 ? Decimal(sd / mean) : 0
        let highVar = cv > AnalysisThresholds.crVarianceThreshold

        let bias = profileCR > 0 ? (medianCR - profileCR) / profileCR : 0
        let needs = abs(bias) > AnalysisThresholds.isfRatioBias && !highVar

        let (sug, adjPct): (Decimal?, Decimal?)
        if needs, profileCR > 0, medianCR > 0 {
            let adj = profileCR * Decimal(0.8) + medianCR * Decimal(0.2)
            sug = adj
            adjPct = ((adj - profileCR) / profileCR) * 100
        } else { sug = nil
            adjPct = nil }

        var conf: ConfidenceLevel = pool.count >= AnalysisThresholds.minimumMealEvents * 3 ? .high
            : pool.count >= AnalysisThresholds.minimumMealEvents ? .moderate : .low
        if highVar, conf > .low { conf = .low }
        if carbCountingConfidence == .rough, conf > .low { conf = .low }

        return SettingScore(
            setting: .cr,
            score: abs(bias),
            needsAdjustment: needs,
            confidence: conf,
            limitHitPercentage: cv * 100,
            cleanDataPointsTotal: pool.count,
            timeBlockAnalyses: [TimeBlockAnalysis(
                blockLabel: "All meals", startMinutes: 0, endMinutes: 1440,
                cleanDataPoints: pool.count, totalDataPoints: valid.count,
                medianDeviation: 0, meanDeviation: 0, deviationP25: 0, deviationP75: 0,
                medianSensitivityRatio: 1, sensitivityRatioAtMax: 0, sensitivityRatioAtMin: 0,
                currentProfileValue: profileCR, suggestedValue: sug, adjustmentPercent: adjPct
            )]
        )
    }

    private func sortedMedian(_ v: [Decimal]) -> Decimal {
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
