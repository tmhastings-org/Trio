import Foundation

public enum TrioAnalyzerKit {

    /// Run the full analysis pipeline.
    public static func analyze(
        logContents: [String],
        settingsCSV: String,
        mealHandling: MealHandlingType,
        carbCounting: CarbCountingConfidence
    ) -> AnalysisReport {
        let logParser = TrioLogParser()
        let settingsParser = TrioSettingsCSVParser()

        let cycles = logParser.parse(logContents: logContents)

        guard var settings = settingsParser.parse(csvContent: settingsCSV) else {
            return errorReport("Failed to parse settings CSV.")
        }

        guard !cycles.isEmpty else {
            return errorReport("No OREF DETERMINATION entries found in log files.")
        }

        // Correct Dynamic ISF mode for known CSV bugs
        if let version = settings.appVersion,
           KnownVersionIssues.csvDynamicISFUnreliable.contains(version) {
            if let detected = TrioSettingsCSVParser.detectDynamicISFFromLogs(logContents),
               detected != settings.dynamicISFMode {
                // Reconstruct settings with corrected mode
                settings = correctedSettings(settings, dynamicISFMode: detected)
            }
        }

        let userProfile = UserProfile(mealHandling: mealHandling, carbCountingConfidence: carbCounting)

        let analyzer = TrioSettingsAnalyzer(
            userTypeDetector: TrioUserTypeDetector(),
            windowClassifier: TrioWindowClassifier(),
            mealEventDetector: TrioMealEventDetector(),
            basalAnalyzer: TrioBasalAnalyzer(),
            isfAnalyzer: TrioISFAnalyzer(),
            crAnalyzer: TrioCRAnalyzer()
        )

        return analyzer.analyze(cycles: cycles, settings: settings, userProfile: userProfile)
    }

    /// Run the full analysis pipeline from already-structured data.
    ///
    /// Use this entry point when data is sourced from Core Data (inside Trio) rather
    /// than from exported log files. Bypasses all log and CSV parsing.
    ///
    /// Build each `LoopCycleData` via `ParsedDetermination.fromRaw(...)` and
    /// construct `TrioSettingsProfile` from Trio's `SettingsManager`.
    public static func analyze(
        cycles: [LoopCycleData],
        settings: TrioSettingsProfile,
        mealHandling: MealHandlingType,
        carbCounting: CarbCountingConfidence
    ) -> AnalysisReport {
        guard !cycles.isEmpty else {
            return errorReport("No loop cycle data provided.")
        }
        let userProfile = UserProfile(mealHandling: mealHandling, carbCountingConfidence: carbCounting)
        let analyzer = TrioSettingsAnalyzer(
            userTypeDetector: TrioUserTypeDetector(),
            windowClassifier: TrioWindowClassifier(),
            mealEventDetector: TrioMealEventDetector(),
            basalAnalyzer: TrioBasalAnalyzer(),
            isfAnalyzer: TrioISFAnalyzer(),
            crAnalyzer: TrioCRAnalyzer()
        )
        return analyzer.analyze(cycles: cycles, settings: settings, userProfile: userProfile)
    }

    /// Parse a Trio settings export CSV into a `TrioSettingsProfile`.
    /// Returns nil if the CSV cannot be parsed.
    /// Use this when constructing cycles from an external source (e.g. Nightscout)
    /// and calling `analyze(cycles:settings:mealHandling:carbCounting:)` directly.
    public static func parseSettings(csvContent: String) -> TrioSettingsProfile? {
        TrioSettingsCSVParser().parse(csvContent: csvContent)
    }

    /// Returns a copy of `settings` with `dynamicISFMode` replaced.
    /// Use this to correct a misreported Dynamic ISF mode in the settings CSV
    /// when log files are unavailable (e.g. the Nightscout CLI path).
    public static func overrideDynamicISFMode(in settings: TrioSettingsProfile, mode: DynamicISFMode) -> TrioSettingsProfile {
        correctedSettings(settings, dynamicISFMode: mode)
    }

    /// Returns true if this version is known to misreport Dynamic ISF mode in the settings CSV.
    /// When true and no log files are available, prompt the user to specify the correct mode
    /// via --dynamic-isf.
    public static func hasKnownCSVDynamicISFBug(version: String) -> Bool {
        KnownVersionIssues.csvDynamicISFUnreliable.contains(version)
    }

    /// Validate inputs before running analysis.
    public static func validateInputs(logContents: [String], settingsCSV: String) -> [String] {
        var issues: [String] = []
        let combined = logContents.joined()
        if combined.isEmpty {
            issues.append("Log files are empty.")
        } else if !combined.contains("OREF DETERMINATION") {
            issues.append("No loop cycle data found in log files.")
        } else {
            let count = combined.components(separatedBy: "OREF DETERMINATION").count - 1
            if count < 20 {
                issues.append("Only \(count) loop cycles found. At least 48 hours (~500 cycles) recommended.")
            }
        }
        if settingsCSV.isEmpty {
            issues.append("Settings file is empty.")
        } else if let settings = TrioSettingsCSVParser().parse(csvContent: settingsCSV) {
            if settings.dia < AnalysisThresholds.minimumDIA {
                issues.append(
                    "DIA is set to \(settings.dia) hours. Analysis requires DIA ≥ \(AnalysisThresholds.minimumDIA) hours. " +
                    "Trio's exponential insulin model is calibrated for 9–10 hours — a lower value causes IOB to be " +
                    "significantly understated, making all results unreliable."
                )
            }
            if let name = settings.insulinName, name.lowercased().contains("lyumjev"),
               !settings.useCustomPeakTime {
                issues.append(
                    "Lyumjev detected without a custom peak time. Lyumjev's peak (~45 min) is faster than the " +
                    "ultra-rapid default (55 min). Enable 'Use Custom Peak Time' in Trio and set it to 45 minutes " +
                    "for more accurate analysis."
                )
            }
            // Warn when known CSV version bug causes Dynamic ISF mode to be misreported
            if let version = settings.appVersion,
               KnownVersionIssues.csvDynamicISFUnreliable.contains(version),
               let detected = TrioSettingsCSVParser.detectDynamicISFFromLogs(logContents),
               detected != settings.dynamicISFMode {
                issues.append(
                    "Dynamic ISF mode in CSV (\(settings.dynamicISFMode.rawValue)) appears to be misreported — " +
                    "a known export bug in v\(version). Log-based detection indicates: \(detected.rawValue). " +
                    "Analysis will use the log-detected mode."
                )
            }
        } else {
            issues.append("Could not parse settings file.")
        }
        return issues
    }

    // MARK: - Helpers

    private static func correctedSettings(_ s: TrioSettingsProfile, dynamicISFMode: DynamicISFMode) -> TrioSettingsProfile {
        TrioSettingsProfile(
            exportDate: s.exportDate, appVersion: s.appVersion, glucoseUnits: s.glucoseUnits,
            basalRates: s.basalRates, isfSchedule: s.isfSchedule, crSchedule: s.crSchedule,
            glucoseTargets: s.glucoseTargets, maxIOB: s.maxIOB, maxBolus: s.maxBolus,
            maxBasalRate: s.maxBasalRate, maxCOB: s.maxCOB, threshold: s.threshold,
            insulinCurve: s.insulinCurve, insulinName: s.insulinName, dia: s.dia, useCustomPeakTime: s.useCustomPeakTime,
            insulinPeakTime: s.insulinPeakTime, autosensMax: s.autosensMax, autosensMin: s.autosensMin,
            dynamicISFMode: dynamicISFMode,
            adjustmentFactor: s.adjustmentFactor, adjustmentFactorSigmoid: s.adjustmentFactorSigmoid,
            weightPercentage: s.weightPercentage, tddAdjustBasal: s.tddAdjustBasal,
            enableSMBAlways: s.enableSMBAlways, enableSMBWithCOB: s.enableSMBWithCOB,
            enableSMBWithTemptarget: s.enableSMBWithTemptarget, enableSMBAfterCarbs: s.enableSMBAfterCarbs,
            enableSMBHighBG: s.enableSMBHighBG, enableSMBHighBGTarget: s.enableSMBHighBGTarget,
            enableUAM: s.enableUAM, maxSMBBasalMinutes: s.maxSMBBasalMinutes,
            maxUAMSMBBasalMinutes: s.maxUAMSMBBasalMinutes, smbDeliveryRatio: s.smbDeliveryRatio,
            maxDeltaBGThreshold: s.maxDeltaBGThreshold,
            highTemptargetRaisesSensitivity: s.highTemptargetRaisesSensitivity,
            lowTemptargetLowersSensitivity: s.lowTemptargetLowersSensitivity,
            sensitivityRaisesTarget: s.sensitivityRaisesTarget,
            resistanceLowersTarget: s.resistanceLowersTarget,
            halfBasalExerciseTarget: s.halfBasalExerciseTarget,
            useFPUConversion: s.useFPUConversion, individualAdjustmentFactor: s.individualAdjustmentFactor,
            fpuDelay: s.fpuDelay, fpuInterval: s.fpuInterval, smoothGlucose: s.smoothGlucose
        )
    }

    private static func errorReport(_ message: String) -> AnalysisReport {
        let empty = SettingScore(setting: .basal, score: 0, needsAdjustment: false,
                                  confidence: .insufficient, limitHitPercentage: 0,
                                  cleanDataPointsTotal: 0, timeBlockAnalyses: [])
        return AnalysisReport(analysisDate: Date(), dataRangeStart: Date(), dataRangeEnd: Date(),
                               totalLoopCycles: 0, settingsTimestamp: nil,
                               userProfile: UserProfile(mealHandling: .varies, carbCountingConfidence: .notApplicable),
                               detectedUserType: DetectedUserType(hasCarbEntries: false, hasFPUEntries: false,
                                   hasManualBoluses: false, medianCarbEntrySize: nil, uamActivePercentage: 0,
                                   inferredType: .varies, agreesWithUserReport: true, disagreementNote: nil),
                               dynamicISFMode: .disabled,
                               glycemicMetrics: nil,
                               basalScore: empty,
                               isfScore: SettingScore(setting: .isf, score: 0, needsAdjustment: false,
                                   confidence: .insufficient, limitHitPercentage: 0,
                                   cleanDataPointsTotal: 0, timeBlockAnalyses: []),
                               crScore: nil, prioritySetting: nil, recommendations: [],
                               mealEvents: nil,
                               warnings: [AnalysisWarning(severity: .critical, message: message)])
    }
}
