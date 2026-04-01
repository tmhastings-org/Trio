import Foundation

// MARK: - ISF Analyzer Protocol

protocol ISFAnalyzer {
    func analyze(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore
}

// MARK: - Three-Path ISF Analyzer

/// Routes ISF analysis through one of three paths based on Dynamic ISF mode:
/// - Logarithmic: Profile ISF is NOT the dosing ISF. Recommends AF adjustment.
/// - Sigmoid: Profile ISF is anchored at target. Uses correction-response analysis.
/// - Static (disabled): Profile ISF is the dosing ISF. Uses ratio bias analysis.
struct TrioISFAnalyzer: ISFAnalyzer {

    func analyze(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore {
        switch settings.dynamicISFMode {
        case .logarithmic:
            return analyzeLogarithmic(classified: classified, settings: settings)
        case .sigmoid:
            return analyzeSigmoid(classified: classified, settings: settings)
        case .disabled:
            return analyzeStatic(classified: classified, settings: settings)
        }
    }

    // MARK: - Logarithmic Analysis

    /// Logarithmic Dynamic ISF: effectiveISF = 1800 / (AF × TDD × ln(BG/insulinFactor + 1))
    /// Profile ISF cancels completely. AF is the only user-accessible lever.
    ///
    /// Suggested AF is derived directly from the formula using median TDD extracted from log
    /// reason strings, the user's glucose target as the BG anchor, and profile ISF.
    /// insulinFactor is determined by the actual algorithm path:
    ///   - useCustomPeakTime = true  → insulinFactor = 120 − insulinPeakTime (from settings)
    ///   - useCustomPeakTime = false → rapid-acting: 55, ultra-rapid: 70, bilinear: 55
    ///
    /// Limit-hitting (% of cycles at autosens_max/min) corroborates the formula signal.
    private func analyzeLogarithmic(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore {
        let clean = classified.filter { $0.isCleanForISF }

        guard clean.count >= AnalysisThresholds.minimumTotalDataPoints else {
            return insufficientScore(setting: .adjustmentFactor, count: clean.count)
        }

        let ratios = clean.compactMap { $0.cycle.determination.sensitivityRatio }
        guard !ratios.isEmpty else {
            return insufficientScore(setting: .adjustmentFactor, count: 0)
        }

        // --- Limit-hitting detection ---
        let atMax = ratios.filter { $0 >= settings.autosensMax - 0.01 }.count
        let atMin = ratios.filter { $0 <= settings.autosensMin + 0.01 }.count
        let limitPct = Decimal(atMax + atMin) / Decimal(max(ratios.count, 1)) * 100
        let limitsFrequentlyHit = limitPct > AnalysisThresholds.logLimitHitAlarmPercent

        // --- Extract median TDD: prefer context (Weighted TDD log line), fallback to reason string ---
        // Use ALL cycles (not just clean) for TDD trend — we want the full picture of how TDD
        // has moved over the data period, regardless of meal/UAM contamination.
        let allTDDs = classified.compactMap { $0.cycle.context?.tdd ?? $0.cycle.determination.reasonTDD }
        let tdds = clean.compactMap { $0.cycle.context?.tdd ?? $0.cycle.determination.reasonTDD }
        let medianTDD = tdds.isEmpty ? nil : sortedMedian(tdds)
        let currentAF = settings.adjustmentFactor

        // --- TDD trend analysis ---
        // Computes coefficient of variation and first-half vs second-half shift
        // to determine whether AF has been consistently miscalibrated or recently became wrong.
        let (tddCoV, tddTrend) = analyzeTDDTrend(allTDDs)

        // --- Formula-based suggested AF ---
        var suggestedAF: Decimal? = nil
        var blockAnalyses: [TimeBlockAnalysis] = []

        if let tdd = medianTDD, tdd > 0 {
            let formulaSuggested = formulaBasedAF(medianTDD: tdd, settings: settings)
            suggestedAF = formulaSuggested

            if let suggested = formulaSuggested {
                let adjPct = ((suggested - currentAF) / currentAF) * 100
                blockAnalyses = [TimeBlockAnalysis(
                    blockLabel: "Formula-based AF estimate",
                    startMinutes: 0, endMinutes: 1440,
                    cleanDataPoints: tdds.count,
                    totalDataPoints: clean.count,
                    medianDeviation: 0, meanDeviation: 0,
                    deviationP25: 0, deviationP75: 0,
                    medianSensitivityRatio: suggested,
                    sensitivityRatioAtMax: atMax, sensitivityRatioAtMin: atMin,
                    currentProfileValue: currentAF,
                    suggestedValue: suggested,
                    adjustmentPercent: adjPct
                )]
            }
        }

        // --- Synthesize: formula signal + limit-hitting corroboration ---
        var needsAdjustment = false
        var afDirection: AFDirection? = nil
        var confidence: ConfidenceLevel = .low

        if let suggested = suggestedAF {
            let afDiff = (suggested - currentAF) / currentAF  // signed fraction
            let afDiffMagnitude = abs(afDiff)
            let formulaDirection: AFDirection = afDiff > 0 ? .increase : .decrease

            // In logarithmic mode, sensitivityRatio at autosensMax means the formula is producing
            // an unnaturally high ratio — AF is too HIGH and should decrease (not increase).
            // Ratio at autosensMin means the formula produces too low a ratio — AF too low, should increase.
            // This is counter-intuitive but follows from: newRatio = profileISF×AF×TDD×ln(BG/f+1)/1800.
            let limitDirectionMatchesFormula = limitsFrequentlyHit &&
                ((atMax > atMin && formulaDirection == .decrease) ||  // both: AF too high
                 (atMin > atMax && formulaDirection == .increase))    // both: AF too low

            if afDiffMagnitude > AnalysisThresholds.afAdjustmentThreshold {
                needsAdjustment = true
                afDirection = formulaDirection
                // Confidence boosted when limit-hitting corroborates the formula direction
                confidence = limitDirectionMatchesFormula ? .high : .moderate
            }
            // else: formula says AF is within threshold — trust it, no adjustment recommended.
            // Limit-hitting in this case is likely driven by BG excursions (e.g., unresolved basal
            // error), not by AF miscalibration. The formula anchors to the target BG; if BG is
            // consistently off-target for other reasons, the limit signal is confounded.
        } else if limitsFrequentlyHit {
            // No TDD data — fall back to limit-hitting alone
            // In logarithmic mode: ratio at max → AF too high (decrease); ratio at min → AF too low (increase).
            needsAdjustment = true
            afDirection = atMax > atMin ? .decrease : .increase
            confidence = limitPct > 40 ? .moderate : .low
        }

        return SettingScore(
            setting: .adjustmentFactor,
            score: limitPct / 100,
            needsAdjustment: needsAdjustment,
            confidence: confidence,
            limitHitPercentage: limitPct,
            cleanDataPointsTotal: clean.count,
            timeBlockAnalyses: blockAnalyses,
            isAFRecommendation: true,
            afDirection: afDirection,
            medianTDD: medianTDD,
            suggestedAF: suggestedAF,
            tddCoefficientOfVariation: tddCoV,
            tddTrend: tddTrend
        )
    }

    // MARK: - TDD Trend Analysis

    /// Computes TDD coefficient of variation and trend direction from a time-ordered TDD series.
    /// Returns (CoV%, TDDTrend). Returns (nil, nil) if fewer than 6 data points.
    ///
    /// Trend is determined by comparing median TDD of the first half vs second half of the period.
    /// A shift > 15% in either direction is classified as rising or falling.
    /// CoV ≥ 25% overrides to .volatile regardless of trend direction.
    private func analyzeTDDTrend(_ tdds: [Decimal]) -> (Decimal?, TDDTrend?) {
        guard tdds.count >= 6 else { return (nil, nil) }

        let doubles = tdds.map { NSDecimalNumber(decimal: $0).doubleValue }
        let mean = doubles.reduce(0, +) / Double(doubles.count)
        guard mean > 0 else { return (nil, nil) }

        let variance = doubles.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(doubles.count)
        let stdDev = variance.squareRoot()
        let covPct = Decimal(stdDev / mean * 100)

        if covPct >= 25 { return (covPct, .volatile) }

        // First vs second half median shift
        let mid = tdds.count / 2
        let firstHalf = Array(tdds.prefix(mid))
        let secondHalf = Array(tdds.suffix(tdds.count - mid))
        let firstMedian = NSDecimalNumber(decimal: sortedMedian(firstHalf)).doubleValue
        let secondMedian = NSDecimalNumber(decimal: sortedMedian(secondHalf)).doubleValue

        guard firstMedian > 0 else { return (covPct, .stable) }
        let shift = (secondMedian - firstMedian) / firstMedian

        let trend: TDDTrend
        if shift > 0.15 { trend = .rising }
        else if shift < -0.15 { trend = .falling }
        else { trend = .stable }

        return (covPct, trend)
    }

    // MARK: - Logarithmic Helpers

    /// Computes the AF value that would make effectiveISF equal profileISF at the user's glucose target.
    ///
    /// Formula: AF = 1800 / (profileISF_mgdL × medianTDD × ln(bgTarget_mgdL / insulinFactor + 1))
    ///
    /// insulinFactor matches what determine-basal.js actually uses:
    ///   useCustomPeakTime = true  → 120 − insulinPeakTime
    ///   useCustomPeakTime = false → curve-type default (rapid-acting: 55, ultra-rapid: 70, bilinear: 55)
    private func formulaBasedAF(medianTDD: Decimal, settings: TrioSettingsProfile) -> Decimal? {
        // Profile ISF: median of schedule, converted to mg/dL.
        // Logarithmic Dynamic ISF users are instructed to set profile ISF to the value
        // that works for corrections at 150 mg/dL. This is the calibration convention.
        guard !settings.isfSchedule.isEmpty else { return nil }
        let profileISFRaw = sortedMedian(settings.isfSchedule.map { $0.value })
        let profileISF_mgdL = settings.glucoseUnits == .mmolL ? profileISFRaw * 18 : profileISFRaw
        guard profileISF_mgdL > 0 else { return nil }

        // BG anchor: fixed at 150 mg/dL (8.33 mmol/L).
        // Logarithmic Dynamic ISF has no built-in anchor BG — unlike sigmoid, which is
        // algebraically anchored at the glucose target. Profile ISF for logarithmic users
        // is calibrated at 150 mg/dL by convention, so that is the correct anchor here.
        let bgAnchor_mgdL: Decimal = 150

        // insulinFactor: matches determine-basal.js logic exactly
        let insulinFactor: Decimal
        if settings.useCustomPeakTime {
            insulinFactor = 120 - settings.insulinPeakTime
        } else {
            switch settings.insulinCurve {
            case .ultraRapid: insulinFactor = 70  // insulinPA = 50
            case .rapidActing, .bilinear: insulinFactor = 55  // insulinPA = 65
            }
        }
        guard insulinFactor > 0 else { return nil }

        // ln(bgAnchor / insulinFactor + 1)
        let ratio = NSDecimalNumber(decimal: bgAnchor_mgdL / insulinFactor).doubleValue + 1.0
        guard ratio > 1.0 else { return nil }
        let lnValue = Decimal(Darwin.log(ratio))
        guard lnValue > 0 else { return nil }

        let suggested = Decimal(1800) / (profileISF_mgdL * medianTDD * lnValue)
        guard suggested > Decimal(string: "0.1")!, suggested < 5 else { return nil }

        // Round to 2 decimal places for display
        var result = Decimal()
        var mutable = suggested
        NSDecimalRound(&result, &mutable, 2, .plain)
        return result
    }

    // MARK: - Sigmoid Analysis

    /// For sigmoid Dynamic ISF users, the profile ISF is the actual ISF used at target BG.
    /// The sensitivity ratio reflects how far from target the user's BG is, NOT whether
    /// ISF is correct.
    ///
    /// Primary method (Tim Street prediction-error):
    /// Uses the loop's own IOB-based BG prediction array as a forward model.
    /// ISF_implied = ISF_used × (BG_t − BG_actual_t+60) / (BG_t − BG_predicted_t+60)
    /// Hepatic glucose cancels out because the profile basal accounts for it equally in
    /// both predicted and actual outcomes. All active IOB is captured by the prediction
    /// array — not just the single delivered SMB — making this more robust than direct
    /// correction-response analysis.
    ///
    /// Fallback (legacy correction-response): used when the prediction array is absent,
    /// which should only occur with very old log formats.
    private func analyzeSigmoid(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore {
        let clean = classified.filter { $0.isCleanForISF }

        guard clean.count >= AnalysisThresholds.minimumTotalDataPoints else {
            return insufficientScore(setting: .isf, count: clean.count)
        }

        let profileISF = sortedMedian(settings.isfSchedule.map { $0.value })

        // Primary: Tim Street prediction-error method
        let impliedSamples = collectPredictionErrorSamples(from: clean)
        if impliedSamples.count >= 4 {
            return buildSigmoidScore(from: impliedSamples, cleanCount: clean.count,
                                     profileISF: profileISF, usedPredictionError: true)
        }

        // Fallback: direct correction-response (no prediction arrays available)
        let correctionSamples = collectCorrectionResponseSamples(from: clean)
        if correctionSamples.count >= 4 {
            return buildSigmoidScore(from: correctionSamples, cleanCount: clean.count,
                                     profileISF: profileISF, usedPredictionError: false)
        }

        return SettingScore(setting: .isf, score: 0, needsAdjustment: false,
                            confidence: .insufficient, limitHitPercentage: 0,
                            cleanDataPointsTotal: clean.count, timeBlockAnalyses: [])
    }

    /// Collects implied ISF samples using the prediction-error method.
    /// For each clean cycle with an IOB prediction array, finds actual BG ~60 min later
    /// and computes: ISF_implied = ISF_used × actualDrop / predictedDrop
    /// Collects actual/predicted BG drop ratios using the prediction-error method.
    /// Samples the ratio: actualDrop / predictedDrop, where predictedDrop comes from
    /// the loop's own IOB-based BG prediction array (predBGs.IOB at index 12 = 60 min).
    ///
    /// Collecting the raw ratio (not ISF_used × ratio) makes this self-normalizing:
    /// it correctly handles periods with different ISF settings and varying effective ISF
    /// from the sigmoid curve, since each sample is evaluated relative to its own prediction.
    ///
    /// responseRatio = median(actualDrop / predictedDrop)
    /// profileISF_implied = profileISF × responseRatio
    private func collectPredictionErrorSamples(from clean: [WindowClassification]) -> [Decimal] {
        var samples: [Decimal] = []

        for i in 0..<clean.count {
            let d = clean[i].cycle.determination
            guard let bgNow = d.bg,
                  let preds = d.iobPredictions, preds.count > 12
            else { continue }

            let predictedBG60 = Decimal(preds[12])  // index 12 = 60 min at 5-min intervals
            let predictedDrop = bgNow - predictedBG60

            // Only use cycles where the IOB prediction shows a meaningful drop.
            // Flat or rising predictions (negative predDrop) produce unreliable ratios.
            guard predictedDrop >= 5 else { continue }

            // Find actual BG 50–80 min later in a clean cycle
            let tsNow = d.timestamp
            for j in (i + 1)..<clean.count {
                let later = clean[j].cycle.determination
                let elapsed = later.timestamp.timeIntervalSince(tsNow)
                if elapsed < 50 * 60 { continue }
                if elapsed > 80 * 60 { break }
                guard let bgLater = later.bg else { continue }

                let actualDrop = bgNow - bgLater

                // Skip if BG rose or barely moved — meal absorption contaminates small drops.
                // BG sensor noise is ~2-3 mg/dL; require at least 5 mg/dL drop for a clean signal.
                // Break rather than continue: contamination at t+60 persists at t+65.
                guard actualDrop >= 5 else { break }

                // Ratio > 0 by construction (both positive drops checked above).
                let ratio = actualDrop / predictedDrop
                samples.append(ratio)
                break
            }
        }

        return samples
    }

    /// Fallback: collects (actualDrop / expectedDrop) ratios using direct correction-response.
    /// Used when prediction arrays are unavailable (old log format).
    /// Ratio interpretation is the same as the prediction-error method.
    private func collectCorrectionResponseSamples(from clean: [WindowClassification]) -> [Decimal] {
        var samples: [Decimal] = []

        for i in 0..<clean.count {
            let d = clean[i].cycle.determination
            guard let smbUnits = d.units, smbUnits > 0,
                  let bgNow = d.bg,
                  let isf = d.isf, isf > 0
            else { continue }

            let expectedDrop = smbUnits * isf
            guard expectedDrop > 0 else { continue }

            let tsNow = d.timestamp
            for j in (i + 1)..<clean.count {
                let later = clean[j].cycle.determination
                let elapsed = later.timestamp.timeIntervalSince(tsNow)
                if elapsed < 45 * 60 { continue }
                if elapsed > 75 * 60 { break }
                guard let bgLater = later.bg else { continue }

                let actualDrop = bgNow - bgLater
                guard actualDrop > 0 else { break }

                let ratio = actualDrop / expectedDrop
                if ratio > 0 { samples.append(ratio) }
                break
            }
        }

        return samples
    }

    /// `ratioSamples` = collection of (actualDrop / predictedDrop) values.
    ///
    /// responseRatio = median ratio:
    ///   > 1.0 → BG drops MORE than predicted → insulin more potent than assumed
    ///           → ISF set too low (algorithm overdoses) → increase profileISF
    ///   < 1.0 → BG drops LESS than predicted → insulin less potent than assumed
    ///           → ISF set too high (algorithm underdoses) → decrease profileISF
    ///
    /// profileISF_implied = profileISF × responseRatio
    private func buildSigmoidScore(
        from ratioSamples: [Decimal],
        cleanCount: Int,
        profileISF: Decimal,
        usedPredictionError: Bool
    ) -> SettingScore {
        let responseRatio = sortedMedian(ratioSamples)

        let confidence: ConfidenceLevel
        if ratioSamples.count >= 10 { confidence = .high }
        else if ratioSamples.count >= 6 { confidence = .moderate }
        else { confidence = .low }

        let bias = abs(responseRatio - 1)
        let needsAdjustment = bias > Decimal(string: "0.15")!

        let suggestedISF: Decimal?
        let adjustmentPct: Decimal?
        if needsAdjustment && responseRatio > 0 {
            // Conservative 20% step toward the implied profile ISF
            let impliedISF = profileISF * responseRatio
            let adjusted = profileISF * Decimal(string: "0.8")! + impliedISF * Decimal(string: "0.2")!
            adjustmentPct = ((adjusted - profileISF) / profileISF) * 100
            suggestedISF = adjusted
        } else {
            suggestedISF = nil
            adjustmentPct = nil
        }

        let label = usedPredictionError ? "Prediction-error analysis" : "Correction-response analysis"
        // medianDeviation expressed as mg/dL equivalent: how far implied profileISF deviates from current
        let impliedISFDeviation = profileISF * responseRatio - profileISF
        let block = TimeBlockAnalysis(
            blockLabel: label,
            startMinutes: 0, endMinutes: 1440,
            cleanDataPoints: ratioSamples.count,
            totalDataPoints: cleanCount,
            medianDeviation: impliedISFDeviation,
            meanDeviation: impliedISFDeviation,
            deviationP25: 0, deviationP75: 0,
            medianSensitivityRatio: responseRatio,
            sensitivityRatioAtMax: 0, sensitivityRatioAtMin: 0,
            currentProfileValue: profileISF,
            suggestedValue: suggestedISF,
            adjustmentPercent: adjustmentPct
        )

        return SettingScore(setting: .isf, score: bias, needsAdjustment: needsAdjustment,
                            confidence: confidence,
                            limitHitPercentage: 0,
                            cleanDataPointsTotal: ratioSamples.count,
                            timeBlockAnalyses: [block])
    }

    // MARK: - Static Analysis

    /// For users with Dynamic ISF disabled, sensitivityRatio reflects autosens adjustments
    /// to the profile ISF. Systematic bias → adjust profile ISF directly.
    ///
    /// Supplementary signal: stable-period back-calculation.
    /// During equilibrium (flat BG, low IOB, no active carbs), the ISF the loop is using
    /// equals effectiveISF = profileISF / sensitivityRatio. Recovering profileISF from
    /// these periods gives a direct empirical estimate independent of autosens smoothing.
    /// If both signals agree on direction, confidence is upgraded.
    private func analyzeStatic(classified: [WindowClassification], settings: TrioSettingsProfile) -> SettingScore {
        let clean = classified.filter { $0.isCleanForISF }

        guard clean.count >= AnalysisThresholds.minimumTotalDataPoints else {
            return insufficientScore(setting: .isf, count: clean.count)
        }

        let ratios = clean.compactMap { $0.cycle.determination.sensitivityRatio }
        guard !ratios.isEmpty else {
            return insufficientScore(setting: .isf, count: 0)
        }

        let medianR = sortedMedian(ratios)
        let atMax = ratios.filter { $0 >= settings.autosensMax - 0.01 }.count
        let atMin = ratios.filter { $0 <= settings.autosensMin + 0.01 }.count
        let limitPct = Decimal(atMax + atMin) / Decimal(max(ratios.count, 1)) * 100

        let bias = abs(medianR - 1.0)
        let needsAdjustment = bias > AnalysisThresholds.isfRatioBias || limitPct > 25

        let profileISF = settings.isfSchedule.first?.value ?? 50

        let suggestedISF: Decimal?
        let adjustmentPct: Decimal?
        if needsAdjustment && medianR > 0 {
            let fullNew = profileISF / medianR
            let adjusted = profileISF * Decimal(string: "0.8")! + fullNew * Decimal(string: "0.2")!
            adjustmentPct = ((adjusted - profileISF) / profileISF) * 100
            suggestedISF = adjusted
        } else {
            suggestedISF = nil
            adjustmentPct = nil
        }

        var confidence: ConfidenceLevel
        if clean.count >= AnalysisThresholds.minimumTotalDataPoints * 3 { confidence = .high }
        else if clean.count >= AnalysisThresholds.minimumTotalDataPoints { confidence = .moderate }
        else { confidence = .low }

        // Stable-period back-calculation: implied profileISF = effectiveISF × sensitivityRatio
        // During flat-BG, low-IOB periods the loop is in equilibrium — this is the most direct
        // read of whether the profile ISF is calibrated correctly.
        let stableSamples = collectStablePeriodISFSamples(from: clean)
        if stableSamples.count >= 6 && needsAdjustment {
            let medianStableISF = sortedMedian(stableSamples)
            let stableBias = (medianStableISF - profileISF) / profileISF
            // If the stable-period signal agrees with the ratio-bias direction, upgrade confidence
            let ratioBiasDirection = medianR > 1 ? 1 : -1   // +1 = ISF too high, -1 = ISF too low
            let stableDirection = stableBias > 0 ? -1 : 1    // +stable ISF > profile = ISF too low
            if ratioBiasDirection == stableDirection && abs(stableBias) > Decimal(string: "0.10")! {
                confidence = confidence == .moderate ? .high : confidence
            }
        }

        return SettingScore(
            setting: .isf,
            score: bias,
            needsAdjustment: needsAdjustment,
            confidence: limitPct > 25 ? .high : confidence,
            limitHitPercentage: limitPct,
            cleanDataPointsTotal: clean.count,
            timeBlockAnalyses: [TimeBlockAnalysis(
                blockLabel: "All hours",
                startMinutes: 0, endMinutes: 1440,
                cleanDataPoints: clean.count,
                totalDataPoints: clean.count,
                medianDeviation: 0, meanDeviation: 0,
                deviationP25: 0, deviationP75: 0,
                medianSensitivityRatio: medianR,
                sensitivityRatioAtMax: atMax,
                sensitivityRatioAtMin: atMin,
                currentProfileValue: profileISF,
                suggestedValue: suggestedISF,
                adjustmentPercent: adjustmentPct
            )]
        )
    }

    /// Collects implied profile ISF values from stable-period cycles.
    /// Equilibrium filter: flat BG (|minDelta| ≤ 3), low IOB (< 1 U), BG in 75–140.
    /// In static mode: profileISF = effectiveISF × sensitivityRatio.
    /// (effectiveISF = ISF field in determination; sensitivityRatio = autosens ratio)
    private func collectStablePeriodISFSamples(from clean: [WindowClassification]) -> [Decimal] {
        clean.compactMap { w -> Decimal? in
            let d = w.cycle.determination
            guard let isf = d.isf, isf > 0,
                  let ratio = d.sensitivityRatio, ratio > 0,
                  let bg = d.bg, bg >= 75 && bg <= 140,
                  let iob = d.iob
            else { return nil }

            let delta = d.minDelta ?? 10
            guard delta >= -3 && delta <= 3 else { return nil }

            let iobDouble = NSDecimalNumber(decimal: iob).doubleValue
            guard iobDouble < 1.0 else { return nil }

            return isf * ratio  // implied profile ISF
        }
    }

    // MARK: - Helpers

    private func insufficientScore(setting: SettingPriority, count: Int) -> SettingScore {
        SettingScore(setting: setting, score: 0, needsAdjustment: false,
                     confidence: .insufficient, limitHitPercentage: 0,
                     cleanDataPointsTotal: count, timeBlockAnalyses: [])
    }

    private func sortedMedian(_ values: [Decimal]) -> Decimal {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid-1] + sorted[mid]) / 2 : sorted[mid]
    }
}
