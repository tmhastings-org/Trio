import Foundation

// MARK: - Analysis Engine

protocol SettingsAnalyzer {
    func analyze(cycles: [LoopCycleData], settings: TrioSettingsProfile, userProfile: UserProfile) -> AnalysisReport
}

struct TrioSettingsAnalyzer: SettingsAnalyzer {
    let userTypeDetector: UserTypeDetector
    let windowClassifier: WindowClassifier
    let mealEventDetector: MealEventDetector
    let basalAnalyzer: BasalAnalyzer
    let isfAnalyzer: ISFAnalyzer
    let crAnalyzer: CRAnalyzer

    func analyze(cycles: [LoopCycleData], settings: TrioSettingsProfile, userProfile: UserProfile) -> AnalysisReport {
        var warnings: [AnalysisWarning] = []

        guard !cycles.isEmpty else {
            return emptyReport(settings: settings, userProfile: userProfile, warnings: [
                AnalysisWarning(severity: .critical, message: "No loop cycle data found in the provided log files.")])
        }

        // DIA gate: the exponential insulin model used in Trio is calibrated for 9–10 hours.
        // Below 7 hours, IOB is significantly understated at every cycle — basal IOB, bolus IOB,
        // BGI, and deviation calculations are all affected. No analysis result can be trusted.
        guard settings.dia >= AnalysisThresholds.minimumDIA else {
            return emptyReport(settings: settings, userProfile: userProfile, warnings: [
                AnalysisWarning(severity: .critical,
                    message: "DIA is set to \(settings.dia) hours. Trio's exponential insulin model " +
                    "requires a DIA of 9–10 hours. Below \(AnalysisThresholds.minimumDIA) hours, IOB is " +
                    "significantly understated and every analysis result — basal, ISF, and CR — would be " +
                    "unreliable. Correct your DIA setting in Trio, export fresh data, and re-run analysis.")])
        }

        // Lyumjev warning: default ultra-rapid peak time (55 min) is too slow for Lyumjev.
        // Lyumjev's published peak is ~45 min. Without a custom peak time, the insulinFactor
        // used in the logarithmic formula will be slightly off (65 vs 75), and ISF timing
        // in correction-response analysis will be imprecise.
        if let name = settings.insulinName, name.lowercased().contains("lyumjev"),
           !settings.useCustomPeakTime {
            warnings.append(AnalysisWarning(severity: .caution,
                message: "Lyumjev detected. Its published insulin peak (~45 min) is faster than the " +
                "ultra-rapid default (55 min) used when 'Use Custom Peak Time' is disabled. " +
                "For best accuracy, enable 'Use Custom Peak Time' in Trio and set it to 45 minutes."))
        }

        let sorted = cycles.sorted { $0.determination.timestamp < $1.determination.timestamp }

        // Step 0: Glycemic metrics + aggressive target warning
        let glycemicMetrics = computeGlycemicMetrics(cycles: sorted)

        // Warn when glucose target is set very aggressively (< 90 mg/dL).
        // At an aggressive target, Trio doses toward the target even when BG is within TIR
        // (e.g. target=80, BG=110 → continuous small corrections). This persistent IOB
        // can contaminate prediction-error ISF analysis and makes "clean basal" windows
        // harder to isolate. The warning flags this so users can weigh the ISF result
        // with appropriate skepticism.
        let effectiveTargetMgdL: Decimal = {
            let raw = settings.glucoseTargets.first?.value ?? 100
            return settings.glucoseUnits == .mmolL ? raw * 18 : raw
        }()
        if effectiveTargetMgdL < 90 {
            let targetDisplay = settings.glucoseUnits == .mmolL
                ? String(format: "%.1f mmol/L", NSDecimalNumber(decimal: effectiveTargetMgdL / 18).doubleValue)
                : "\(Int(NSDecimalNumber(decimal: effectiveTargetMgdL).doubleValue)) mg/dL"
            warnings.append(AnalysisWarning(severity: .info,
                message: "Glucose target is set aggressively (\(targetDisplay)). Trio will dose toward " +
                "this target even when BG is within range, creating persistent low-level IOB. " +
                "This may affect prediction-error ISF analysis accuracy. " +
                "Validate ISF results in the context of your actual time in range."))
        }

        // Step 1: Detect user type
        let detectedType = userTypeDetector.detect(cycles: sorted, settings: settings, userReport: userProfile.mealHandling)
        if !detectedType.agreesWithUserReport, let note = detectedType.disagreementNote {
            warnings.append(AnalysisWarning(severity: .caution, message: note))
        }

        // Warn no-carb users about analysis limitations
        if detectedType.inferredType == .noEntry && detectedType.uamActivePercentage > 60 {
            let uamInt = Int(NSDecimalNumber(decimal: detectedType.uamActivePercentage).doubleValue.rounded())
            warnings.append(AnalysisWarning(severity: .caution,
                message: "UAM is active \(uamInt)% of the time. " +
                "Without carb entries, the tool cannot distinguish basal errors from meal-related glucose rises. " +
                "Basal recommendations are limited to periods where UAM is inactive."))
        }

        // Step 2: Classify windows
        let classified = windowClassifier.classify(cycles: sorted, settings: settings, userType: detectedType)

        // Step 3: Detect meals
        let mealEvents: [MealEvent]?
        let skipCR: Bool
        switch detectedType.inferredType {
        case .noEntry, .manualBolusOnly: mealEvents = nil; skipCR = true
        default:
            mealEvents = mealEventDetector.detect(cycles: sorted, settings: settings, userType: detectedType)
            skipCR = false
        }

        // Step 4: Basal analysis
        let basalScore = basalAnalyzer.analyze(classified: classified, settings: settings)

        // Step 5: ISF analysis (mode-specific)
        var isfScore = isfAnalyzer.analyze(classified: classified, settings: settings)
        if basalScore.needsAdjustment {
            isfScore = downgradeConfidence(isfScore,
                reason: "ISF analysis may be affected by basal rate errors detected in this dataset.")
        }

        // Step 6: CR analysis
        var crScore: SettingScore? = nil
        if !skipCR, let meals = mealEvents {
            var raw = crAnalyzer.analyze(classified: classified, mealEvents: meals,
                                          settings: settings, carbCountingConfidence: userProfile.carbCountingConfidence)
            if basalScore.needsAdjustment || isfScore.needsAdjustment {
                raw = downgradeConfidence(raw,
                    reason: "CR analysis may be affected by \(basalScore.needsAdjustment ? "basal" : "ISF") errors.")
            }
            crScore = raw
        }

        // Step 7: Priority decision
        let (priority, recs) = buildPriority(
            basalScore: basalScore, isfScore: isfScore, crScore: crScore,
            settings: settings, userType: detectedType, userProfile: userProfile, warnings: &warnings)

        return AnalysisReport(
            analysisDate: Date(),
            dataRangeStart: sorted.first!.determination.timestamp,
            dataRangeEnd: sorted.last!.determination.timestamp,
            totalLoopCycles: sorted.count,
            settingsTimestamp: settings.exportDate,
            userProfile: userProfile,
            detectedUserType: detectedType,
            dynamicISFMode: settings.dynamicISFMode,
            glycemicMetrics: glycemicMetrics,
            basalScore: basalScore, isfScore: isfScore, crScore: crScore,
            prioritySetting: priority, recommendations: recs,
            mealEvents: mealEvents, warnings: warnings)
    }

    // MARK: - Priority Logic

    private func buildPriority(
        basalScore: SettingScore, isfScore: SettingScore, crScore: SettingScore?,
        settings: TrioSettingsProfile, userType: DetectedUserType,
        userProfile: UserProfile, warnings: inout [AnalysisWarning]
    ) -> (SettingPriority?, [SettingRecommendation]) {

        // Case 1: Basal needs adjustment
        if basalScore.needsAdjustment && basalScore.confidence != .insufficient {
            let recs = buildBasalRecommendations(basalScore, settings: settings)

            if isfScore.needsAdjustment || crScore?.needsAdjustment == true {
                let isfLabel = isfScore.isAFRecommendation ? "Adjustment Factor" : "ISF"
                warnings.append(AnalysisWarning(severity: .info,
                    message: "\(isfLabel) may also need adjustment, but basal must be corrected first. Re-analyze after 48 hours with updated basals."))
            }
            return (.basal, recs)
        }

        // Case 2: ISF / AF needs adjustment
        if isfScore.needsAdjustment && isfScore.confidence != .insufficient {
            let priority: SettingPriority = isfScore.isAFRecommendation ? .adjustmentFactor : .isf
            let recs = buildISFRecommendations(isfScore, settings: settings)

            if crScore?.needsAdjustment == true {
                warnings.append(AnalysisWarning(severity: .info,
                    message: "CR may also need adjustment, but \(isfScore.isAFRecommendation ? "AF" : "ISF") must be corrected first. Re-analyze after 48 hours."))
            }
            return (priority, recs)
        }

        // Case 3: CR needs adjustment
        if let crScore = crScore, crScore.needsAdjustment && crScore.confidence != .insufficient {
            if userProfile.carbCountingConfidence == .rough {
                warnings.append(AnalysisWarning(severity: .caution,
                    message: "You indicated your carb counting is rough estimates. Improving counting consistency would likely help more than adjusting CR."))
            }
            if settings.useFPUConversion && userType.hasFPUEntries {
                warnings.append(AnalysisWarning(severity: .caution,
                    message: "You use fat/protein conversion. Meal outcome errors may be from FPU settings rather than CR itself."))
            }
            let recs = buildCRRecommendations(crScore, settings: settings)
            return (.cr, recs)
        }

        // Case 4: All clean
        if basalScore.confidence != .insufficient && isfScore.confidence != .insufficient {
            warnings.append(AnalysisWarning(severity: .info,
                message: "Your settings appear well-calibrated based on the available data. " +
                "No adjustments are expected to improve time in range. " +
                "If your TIR (70–180 mg/dL) is not meeting your goals, consider non-settings factors " +
                "such as meal timing, activity, or stress."))
        }
        return (nil, [])
    }

    // MARK: - Recommendation Builders

    private func buildBasalRecommendations(_ score: SettingScore, settings: TrioSettingsProfile) -> [SettingRecommendation] {
        score.timeBlockAnalyses.compactMap { block -> SettingRecommendation? in
            guard let _ = block.suggestedValue, let adjPct = block.adjustmentPercent,
                  block.cleanDataPoints >= AnalysisThresholds.minimumDataPointsPerBlock else { return nil }

            let capped = max(-AnalysisThresholds.maxAdjustmentPercent,
                              min(AnalysisThresholds.maxAdjustmentPercent, adjPct))
            let cappedVal = block.currentProfileValue * (1 + capped / 100)
            let rounded = roundBasal(cappedVal)
            guard rounded != block.currentProfileValue else { return nil }
            let conf = block.cleanDataPoints >= 18 ? ConfidenceLevel.high
                : block.cleanDataPoints >= 6 ? .moderate : .low

            let dir = capped > 0 ? "increase" : "decrease"
            var rationale: String
            let ratioDouble = NSDecimalNumber(decimal: block.medianSensitivityRatio).doubleValue
            let isRatioBased = abs(block.medianDeviation) <= AnalysisThresholds.basalDeviationMagnitude
                               && abs(ratioDouble - 1.0) >= 0.05

            if isRatioBased {
                let ratioPct = String(format: "%.1f", abs(ratioDouble - 1.0) * 100)
                let ratioDir = ratioDouble > 1 ? "high" : "low"
                let tirImpact = ratioDouble > 1
                    ? "A basal that is too low often contributes to time above range, particularly during fasting periods."
                    : "A basal that is too high can cause BG to drop during fasting, increasing time below range."
                rationale = "Autosens is consistently running \(ratioPct)% \(ratioDir) in \(block.blockLabel), "
                rationale += "indicating it is compensating for a profile basal that is too \(ratioDouble > 1 ? "low" : "high"). "
                rationale += "BG deviation is quiet because autosens is masking the problem. "
                rationale += "\(tirImpact) "
                rationale += "Profile basal should be adjusted so autosens returns toward 1.0. "
                rationale += "Validate ISF only after confirming basal is stable. "
            } else {
                let devDir = block.medianDeviation > 0 ? "positive" : "negative"
                let tirImpact = block.medianDeviation > 0
                    ? "Uncorrected basal that is too low typically causes BG to drift upward during fasting, increasing time above range."
                    : "Uncorrected basal that is too high causes BG to drop during fasting, increasing time below range."
                rationale = "Based on \(block.cleanDataPoints) clean data points in \(block.blockLabel), "
                rationale += "median deviation was \(devDir) (\(block.medianDeviation) mg/dL/30m), "
                rationale += "suggesting basal is \(block.medianDeviation > 0 ? "too low" : "too high"). "
                rationale += "\(tirImpact) "
            }
            rationale += "Recommended \(dir) of \(roundPct(abs(capped)))%."

            return SettingRecommendation(setting: .basal, timeBlockLabel: block.blockLabel,
                currentValue: block.currentProfileValue, suggestedValue: rounded,
                adjustmentPercent: capped, uncappedAdjustmentPercent: adjPct,
                confidence: conf, cleanDataPoints: block.cleanDataPoints, rationale: rationale)
        }
    }

    private func buildISFRecommendations(_ score: SettingScore, settings: TrioSettingsProfile) -> [SettingRecommendation] {
        if score.isAFRecommendation {
            return buildAFRecommendations(score, settings: settings)
        }

        return score.timeBlockAnalyses.compactMap { block -> SettingRecommendation? in
            guard let _ = block.suggestedValue, let adjPct = block.adjustmentPercent else { return nil }

            let capped = max(-AnalysisThresholds.maxAdjustmentPercent,
                              min(AnalysisThresholds.maxAdjustmentPercent, adjPct))
            let cappedVal = block.currentProfileValue * (1 + capped / 100)
            let rounded = settings.glucoseUnits == .mgdL
                ? cappedVal.rounded() : (cappedVal * 10).rounded() / 10
            guard rounded != block.currentProfileValue else { return nil }

            return SettingRecommendation(setting: .isf, timeBlockLabel: block.blockLabel,
                currentValue: block.currentProfileValue, suggestedValue: rounded,
                adjustmentPercent: capped, uncappedAdjustmentPercent: adjPct,
                confidence: score.confidence, cleanDataPoints: block.cleanDataPoints,
                rationale: buildISFRationale(block: block, score: score, settings: settings))
        }
    }

    private func buildAFRecommendations(_ score: SettingScore, settings: TrioSettingsProfile) -> [SettingRecommendation] {
        guard let direction = score.afDirection else { return [] }

        let currentAF = settings.adjustmentFactor
        let limitsHit = score.limitHitPercentage > AnalysisThresholds.logLimitHitAlarmPercent

        // Case A: Formula analysis produced a specific implied AF target.
        // AF is not capped at 20% — unlike empirical ISF/basal adjustments, the formula gives us
        // the exact calibration target. The appropriate caution depends on TDD stability, not
        // an arbitrary step size.
        if let impliedAF = score.suggestedAF {
            let adjustmentPct = ((impliedAF - currentAF) / currentAF) * 100
            let targetAF = (impliedAF * 100).rounded() / 100

            let tddStr = score.medianTDD.map { "\(roundAF($0))" } ?? "unknown"
            var rationale = "Formula-based target using median weighted TDD of \(tddStr) U/day, "
            rationale += "anchored at 150 mg/dL (the calibration BG for logarithmic Dynamic ISF — "
            rationale += "profile ISF should be set to the value that works for corrections at 150 mg/dL). "
            rationale += "Target AF: \(afPct(impliedAF)) (current: \(afPct(currentAF))). "

            // Interpret TDD trend to guide confidence in the target
            switch score.tddTrend {
            case .stable:
                rationale += "TDD has been stable across the analysis period — the formula target is reliable. "
                rationale += "AF has been miscalibrated for the full data window. Set AF to \(afPct(impliedAF)) directly. "
            case .rising:
                rationale += "TDD has been rising during the analysis period, suggesting recent insulin need has increased. "
                rationale += "AF may have been closer to correct earlier. Set to \(afPct(impliedAF)) and recheck after 5–7 days as TDD stabilizes. "
            case .falling:
                rationale += "TDD has been falling during the analysis period. "
                rationale += "Set to \(afPct(impliedAF)) and recheck after 5–7 days as TDD stabilizes. "
            case .volatile:
                let covStr = score.tddCoefficientOfVariation.map { "\(roundPct($0))%" } ?? "high"
                rationale += "TDD has been highly variable (CoV: \(covStr)) — the median is less reliable as a calibration anchor. "
                rationale += "Set AF to \(afPct(impliedAF)) as a starting point and recheck weekly until TDD stabilizes. "
            case nil:
                rationale += "Insufficient TDD data to assess stability. "
                rationale += "Set AF to \(afPct(impliedAF)) and recheck after 5–7 days. "
            }

            if limitsHit {
                rationale += "Autosens limits are also being hit (\(roundPct(score.limitHitPercentage))% of cycles), "
                rationale += "which corroborates the formula finding. "
            }

            rationale += "AF is the primary tuning lever for logarithmic Dynamic ISF."

            // Build per-range recommendations when block data is available
            if score.timeBlockAnalyses.count > 1 {
                return score.timeBlockAnalyses.compactMap { block -> SettingRecommendation? in
                    guard let blockAF = block.suggestedValue, let adjPct = block.adjustmentPercent else { return nil }
                    let blockTargetAF = (blockAF * 100).rounded() / 100
                    return SettingRecommendation(
                        setting: .adjustmentFactor, timeBlockLabel: block.blockLabel,
                        currentValue: currentAF, suggestedValue: blockTargetAF,
                        adjustmentPercent: adjPct, uncappedAdjustmentPercent: adjPct,
                        confidence: score.confidence, cleanDataPoints: block.cleanDataPoints,
                        rationale: "Implied AF from \(block.cleanDataPoints) corrections at \(block.blockLabel): \(afPct(blockAF))."
                    )
                }
            }

            // Single overall recommendation
            return [SettingRecommendation(
                setting: .adjustmentFactor, timeBlockLabel: "All BG ranges",
                currentValue: currentAF, suggestedValue: targetAF,
                adjustmentPercent: adjustmentPct, uncappedAdjustmentPercent: adjustmentPct,
                confidence: score.confidence, cleanDataPoints: score.cleanDataPointsTotal,
                rationale: rationale
            )]
        }

        // Case B: Limit-hitting only — AF or autosens limits may be the cause.
        // With insufficient correction data we can give direction but not a specific target.
        var rationale = ""
        switch direction {
        case .increase:
            rationale = "autosens_max (\(settings.autosensMax)) is being hit in \(score.limitHitPercentage)% of cycles. "
            rationale += "This means the formula consistently wants a more aggressive ISF than the ceiling allows. "
            rationale += "Two possible causes: (1) Adjustment Factor (\(afPct(currentAF))) is too low, "
            rationale += "or (2) autosens_max is set too low for this user's typical BG range. "
            rationale += "Collect more data to determine which — if correction events show the current AF is calibrated correctly, "
            rationale += "consider raising autosens_max instead."
        case .decrease:
            rationale = "autosens_min (\(settings.autosensMin)) is being hit in \(score.limitHitPercentage)% of cycles. "
            rationale += "The formula consistently wants a less aggressive ISF than the floor allows. "
            rationale += "Two possible causes: (1) Adjustment Factor (\(afPct(currentAF))) is too high, "
            rationale += "or (2) autosens_min is set too high. "
            rationale += "Collect more data to determine which."
        }
        rationale += " Profile ISF has no effect on logarithmic dosing — AF and autosens limits are the correct levers."

        return [SettingRecommendation(
            setting: .adjustmentFactor, timeBlockLabel: "All hours",
            currentValue: currentAF, suggestedValue: nil,
            adjustmentPercent: nil, uncappedAdjustmentPercent: nil,
            confidence: score.confidence, cleanDataPoints: score.cleanDataPointsTotal,
            rationale: rationale
        )]
    }

    private func roundAF(_ value: Decimal) -> Decimal {
        (value * 100).rounded() / 100   // 2 decimal places
    }

    /// Formats an AF decimal value as a percentage string matching Trio's in-app display.
    /// e.g. 0.9 → "90%", 0.875 → "87.5%"
    private func afPct(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue * 100
        return d.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f%%", d)
            : String(format: "%.1f%%", d)
    }

    private func roundPct(_ value: Decimal) -> Decimal {
        (value * 10).rounded() / 10     // 1 decimal place
    }

    private func buildCRRecommendations(_ score: SettingScore, settings: TrioSettingsProfile) -> [SettingRecommendation] {
        score.timeBlockAnalyses.compactMap { block -> SettingRecommendation? in
            guard let _ = block.suggestedValue, let adjPct = block.adjustmentPercent else { return nil }
            let capped = max(-AnalysisThresholds.maxAdjustmentPercent,
                              min(AnalysisThresholds.maxAdjustmentPercent, adjPct))
            let rounded = (block.currentProfileValue * (1 + capped / 100) * 10).rounded() / 10
            guard rounded != block.currentProfileValue else { return nil }

            return SettingRecommendation(setting: .cr, timeBlockLabel: block.blockLabel,
                currentValue: block.currentProfileValue, suggestedValue: rounded,
                adjustmentPercent: capped, uncappedAdjustmentPercent: adjPct,
                confidence: score.confidence, cleanDataPoints: block.cleanDataPoints,
                rationale: "Meal outcomes suggest CR adjustment of \(roundPct(abs(capped)))%.")
        }
    }

    // MARK: - Helpers

    private func buildISFRationale(block: TimeBlockAnalysis, score: SettingScore, settings: TrioSettingsProfile) -> String {
        var r = "Based on \(block.cleanDataPoints) data points, "
        if settings.dynamicISFMode == .sigmoid {
            let ratio = block.medianSensitivityRatio
            r += "median actual/predicted BG drop ratio was \(roundAF(ratio)). "
            if ratio > 1 {
                r += "BG is responding more than the IOB prediction expected — insulin is more potent than the profile assumes. "
                r += "Profile ISF appears too low. Increasing it reduces how much insulin Trio delivers per correction, "
                r += "lowering the risk of overcorrection and time spent below range."
            } else {
                r += "BG is responding less than the IOB prediction expected — insulin is less potent than the profile assumes. "
                r += "Profile ISF appears too high. Decreasing it increases how much insulin Trio delivers per correction, "
                r += "which should reduce time above range (>140 mg/dL) when corrections are needed."
            }
        } else {
            let dir = block.medianSensitivityRatio > 1 ? "above" : "below"
            let tirImpact = block.medianSensitivityRatio > 1
                ? "ISF too high causes underdosing during corrections, contributing to time above range."
                : "ISF too low causes overdosing during corrections, contributing to time below range."
            r += "autosens ratio consistently \(dir) 1.0 (median \(block.medianSensitivityRatio)), "
            r += "suggesting ISF is \(block.medianSensitivityRatio > 1 ? "too high" : "too low"). "
            r += "\(tirImpact)"
            if block.sensitivityRatioAtMax > 0 || block.sensitivityRatioAtMin > 0 {
                r += " Autosens hit limits in \(block.sensitivityRatioAtMax + block.sensitivityRatioAtMin) cycles."
            }
        }
        return r
    }

    private func downgradeConfidence(_ score: SettingScore, reason: String) -> SettingScore {
        let new: ConfidenceLevel
        switch score.confidence {
        case .high: new = .moderate; case .moderate: new = .low; default: new = .insufficient
        }
        return SettingScore(setting: score.setting, score: score.score, needsAdjustment: score.needsAdjustment,
                            confidence: new, limitHitPercentage: score.limitHitPercentage,
                            cleanDataPointsTotal: score.cleanDataPointsTotal, timeBlockAnalyses: score.timeBlockAnalyses,
                            isAFRecommendation: score.isAFRecommendation, afDirection: score.afDirection,
                            medianTDD: score.medianTDD, suggestedAF: score.suggestedAF)
    }

    private func roundBasal(_ value: Decimal) -> Decimal {
        (value * 20).rounded() / 20  // 0.05 increments
    }

    // MARK: - Glycemic Metrics

    private func computeGlycemicMetrics(cycles: [LoopCycleData]) -> GlycemicMetrics? {
        // Collect BG values from all cycles (not just clean ones — we want the full picture).
        // bg is always stored in mg/dL in Trio's devicestatus output.
        // Exclude known CGM error codes: ≤10 and 38 (Dexcom sensor error placeholder).
        let bgs = cycles.compactMap { $0.determination.bg }
            .map { NSDecimalNumber(decimal: $0).doubleValue }
            .filter { $0 > 10 && $0 != 38 }
        guard bgs.count >= 10 else { return nil }

        let n = bgs.count
        let inRange  = bgs.filter { $0 >= 70 && $0 <= 180 }.count
        let inTight  = bgs.filter { $0 >= 70 && $0 <= 140 }.count
        let below    = bgs.filter { $0 < 70 }.count
        let above    = bgs.filter { $0 > 180 }.count

        let sorted = bgs.sorted()
        let mid = sorted.count / 2
        let medianBG = sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]

        func pct(_ count: Int) -> Decimal { Decimal(count * 1000 / n) / 10 }

        return GlycemicMetrics(
            timeInRange:       pct(inRange),
            timeInTightRange:  pct(inTight),
            timeBelowRange:    pct(below),
            timeAboveRange:    pct(above),
            medianGlucose:     Decimal(Int(medianBG.rounded())),
            bgReadingCount:    n
        )
    }

    private func emptyReport(settings: TrioSettingsProfile, userProfile: UserProfile, warnings: [AnalysisWarning]) -> AnalysisReport {
        let empty = SettingScore(setting: .basal, score: 0, needsAdjustment: false,
                                  confidence: .insufficient, limitHitPercentage: 0,
                                  cleanDataPointsTotal: 0, timeBlockAnalyses: [])
        return AnalysisReport(analysisDate: Date(), dataRangeStart: Date(), dataRangeEnd: Date(),
                               totalLoopCycles: 0, settingsTimestamp: nil,
                               userProfile: userProfile,
                               detectedUserType: DetectedUserType(hasCarbEntries: false, hasFPUEntries: false,
                                   hasManualBoluses: false, medianCarbEntrySize: nil, uamActivePercentage: 0,
                                   inferredType: userProfile.mealHandling, agreesWithUserReport: true, disagreementNote: nil),
                               dynamicISFMode: settings.dynamicISFMode,
                               glycemicMetrics: nil,
                               basalScore: empty,
                               isfScore: SettingScore(setting: .isf, score: 0, needsAdjustment: false,
                                   confidence: .insufficient, limitHitPercentage: 0,
                                   cleanDataPointsTotal: 0, timeBlockAnalyses: []),
                               crScore: nil, prioritySetting: nil, recommendations: [],
                               mealEvents: nil, warnings: warnings)
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var result = Decimal()
        var mutable = self
        NSDecimalRound(&result, &mutable, 0, .plain)
        return result
    }
}
