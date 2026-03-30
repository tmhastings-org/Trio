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
                message: "Your settings appear well-tuned based on the available data. No adjustments recommended."))
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
            let devDir = block.medianDeviation > 0 ? "positive" : "negative"
            var rationale = "Based on \(block.cleanDataPoints) clean data points in \(block.blockLabel), "
            rationale += "median deviation was \(devDir) (\(block.medianDeviation) mg/dL/30m), "
            rationale += "suggesting basal is \(block.medianDeviation > 0 ? "too low" : "too high"). "
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

        // Case A: Empirical analysis produced a specific implied AF target
        if let impliedAF = score.suggestedAF {
            let uncappedPct = ((impliedAF - currentAF) / currentAF) * 100
            let cappedPct = max(-AnalysisThresholds.maxAdjustmentPercent,
                                 min(AnalysisThresholds.maxAdjustmentPercent, uncappedPct))
            let cappedAF = (currentAF * (1 + cappedPct / 100) * 100).rounded() / 100

            let tddStr = score.medianTDD.map { "\(roundAF($0))" } ?? "unknown"
            var rationale = "Formula-based estimate using median TDD of \(tddStr) U/day "
            rationale += "and your glucose target as the anchor. "
            rationale += "Suggested AF: \(roundAF(impliedAF)) (current: \(currentAF)). "

            if abs(uncappedPct) > AnalysisThresholds.maxAdjustmentPercent {
                rationale += "Full adjustment (\(roundPct(uncappedPct))%) exceeds the 20% single-iteration cap. "
                rationale += "Apply \(roundPct(cappedPct))% now and re-analyze after 48 hours. "
            }

            if limitsHit {
                rationale += "Autosens limits are also being hit (\(roundPct(score.limitHitPercentage))% of cycles), "
                rationale += "which corroborates the formula finding. "
            }

            rationale += "Profile ISF has no effect on logarithmic dosing — AF is the correct lever."

            // Build per-range recommendations when block data is available
            if score.timeBlockAnalyses.count > 1 {
                return score.timeBlockAnalyses.compactMap { block -> SettingRecommendation? in
                    guard let blockAF = block.suggestedValue, let adjPct = block.adjustmentPercent else { return nil }
                    let blockCapped = max(-AnalysisThresholds.maxAdjustmentPercent,
                                          min(AnalysisThresholds.maxAdjustmentPercent, adjPct))
                    let blockCappedAF = (currentAF * (1 + blockCapped / 100) * 100).rounded() / 100
                    return SettingRecommendation(
                        setting: .adjustmentFactor, timeBlockLabel: block.blockLabel,
                        currentValue: currentAF, suggestedValue: blockCappedAF,
                        adjustmentPercent: blockCapped, uncappedAdjustmentPercent: adjPct,
                        confidence: score.confidence, cleanDataPoints: block.cleanDataPoints,
                        rationale: "Implied AF from \(block.cleanDataPoints) corrections at \(block.blockLabel): \(roundAF(blockAF))."
                    )
                }
            }

            // Single overall recommendation
            return [SettingRecommendation(
                setting: .adjustmentFactor, timeBlockLabel: "All BG ranges",
                currentValue: currentAF, suggestedValue: cappedAF,
                adjustmentPercent: cappedPct, uncappedAdjustmentPercent: uncappedPct,
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
            rationale += "Two possible causes: (1) Adjustment Factor (\(currentAF)) is too low, "
            rationale += "or (2) autosens_max is set too low for this user's typical BG range. "
            rationale += "Collect more data to determine which — if correction events show the current AF is calibrated correctly, "
            rationale += "consider raising autosens_max instead."
        case .decrease:
            rationale = "autosens_min (\(settings.autosensMin)) is being hit in \(score.limitHitPercentage)% of cycles. "
            rationale += "The formula consistently wants a less aggressive ISF than the floor allows. "
            rationale += "Two possible causes: (1) Adjustment Factor (\(currentAF)) is too high, "
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
                r += "BG is responding more than the IOB prediction expected — insulin more potent than assumed. "
                r += "Profile ISF appears too low — consider increasing to reduce insulin delivery."
            } else {
                r += "BG is responding less than the IOB prediction expected — insulin less potent than assumed. "
                r += "Profile ISF appears too high — consider decreasing to increase insulin delivery."
            }
        } else {
            let dir = block.medianSensitivityRatio > 1 ? "above" : "below"
            r += "autosens ratio consistently \(dir) 1.0 (median \(block.medianSensitivityRatio)), "
            r += "suggesting ISF is \(block.medianSensitivityRatio > 1 ? "too high" : "too low")."
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
