import Foundation

// MARK: - User Input

public enum MealHandlingType: String, Codable, CaseIterable {
    case noEntry = "no_entry"
    case manualBolusOnly = "manual_bolus"
    case carbsOnly = "carbs_only"
    case carbsFatProtein = "carbs_fat_protein"
    case varies = "varies"
}

public enum CarbCountingConfidence: String, Codable, CaseIterable {
    case precise = "precise"
    case reasonable = "reasonable"
    case rough = "rough"
    case notApplicable = "n_a"
}

public struct UserProfile: Codable {
    public let mealHandling: MealHandlingType
    public let carbCountingConfidence: CarbCountingConfidence
    public init(mealHandling: MealHandlingType, carbCountingConfidence: CarbCountingConfidence) {
        self.mealHandling = mealHandling; self.carbCountingConfidence = carbCountingConfidence
    }
}

// MARK: - Parsed Settings

public struct TrioSettingsProfile: Codable {
    public let exportDate: Date?
    public let appVersion: String?
    public let glucoseUnits: GlucoseUnit
    public let basalRates: [ScheduleEntry]
    public let isfSchedule: [ScheduleEntry]
    public let crSchedule: [ScheduleEntry]
    public let glucoseTargets: [ScheduleEntry]
    public let maxIOB: Decimal
    public let maxBolus: Decimal
    public let maxBasalRate: Decimal
    public let maxCOB: Decimal
    public let threshold: Decimal
    public let insulinCurve: InsulinCurveType
    public let insulinName: String?           // Raw insulin type name as exported from Trio
    public let dia: Decimal
    public let useCustomPeakTime: Bool
    public let insulinPeakTime: Decimal
    public let autosensMax: Decimal
    public let autosensMin: Decimal
    public let dynamicISFMode: DynamicISFMode
    public let adjustmentFactor: Decimal
    public let adjustmentFactorSigmoid: Decimal
    public let weightPercentage: Decimal
    public let tddAdjustBasal: Bool
    public let enableSMBAlways: Bool
    public let enableSMBWithCOB: Bool
    public let enableSMBWithTemptarget: Bool
    public let enableSMBAfterCarbs: Bool
    public let enableSMBHighBG: Bool
    public let enableSMBHighBGTarget: Decimal
    public let enableUAM: Bool
    public let maxSMBBasalMinutes: Decimal
    public let maxUAMSMBBasalMinutes: Decimal
    public let smbDeliveryRatio: Decimal
    public let maxDeltaBGThreshold: Decimal
    public let highTemptargetRaisesSensitivity: Bool
    public let lowTemptargetLowersSensitivity: Bool
    public let sensitivityRaisesTarget: Bool
    public let resistanceLowersTarget: Bool
    public let halfBasalExerciseTarget: Decimal
    public let useFPUConversion: Bool
    public let individualAdjustmentFactor: Decimal
    public let fpuDelay: Decimal
    public let fpuInterval: Decimal
    public let smoothGlucose: Bool

    public init(
        exportDate: Date?, appVersion: String?, glucoseUnits: GlucoseUnit,
        basalRates: [ScheduleEntry], isfSchedule: [ScheduleEntry], crSchedule: [ScheduleEntry],
        glucoseTargets: [ScheduleEntry], maxIOB: Decimal, maxBolus: Decimal,
        maxBasalRate: Decimal, maxCOB: Decimal, threshold: Decimal,
        insulinCurve: InsulinCurveType, insulinName: String?, dia: Decimal,
        useCustomPeakTime: Bool, insulinPeakTime: Decimal,
        autosensMax: Decimal, autosensMin: Decimal, dynamicISFMode: DynamicISFMode,
        adjustmentFactor: Decimal, adjustmentFactorSigmoid: Decimal,
        weightPercentage: Decimal, tddAdjustBasal: Bool,
        enableSMBAlways: Bool, enableSMBWithCOB: Bool, enableSMBWithTemptarget: Bool,
        enableSMBAfterCarbs: Bool, enableSMBHighBG: Bool, enableSMBHighBGTarget: Decimal,
        enableUAM: Bool, maxSMBBasalMinutes: Decimal, maxUAMSMBBasalMinutes: Decimal,
        smbDeliveryRatio: Decimal, maxDeltaBGThreshold: Decimal,
        highTemptargetRaisesSensitivity: Bool, lowTemptargetLowersSensitivity: Bool,
        sensitivityRaisesTarget: Bool, resistanceLowersTarget: Bool,
        halfBasalExerciseTarget: Decimal, useFPUConversion: Bool,
        individualAdjustmentFactor: Decimal, fpuDelay: Decimal,
        fpuInterval: Decimal, smoothGlucose: Bool
    ) {
        self.exportDate = exportDate; self.appVersion = appVersion
        self.glucoseUnits = glucoseUnits; self.basalRates = basalRates
        self.isfSchedule = isfSchedule; self.crSchedule = crSchedule
        self.glucoseTargets = glucoseTargets; self.maxIOB = maxIOB
        self.maxBolus = maxBolus; self.maxBasalRate = maxBasalRate
        self.maxCOB = maxCOB; self.threshold = threshold
        self.insulinCurve = insulinCurve; self.insulinName = insulinName
        self.dia = dia; self.useCustomPeakTime = useCustomPeakTime
        self.insulinPeakTime = insulinPeakTime; self.autosensMax = autosensMax
        self.autosensMin = autosensMin; self.dynamicISFMode = dynamicISFMode
        self.adjustmentFactor = adjustmentFactor; self.adjustmentFactorSigmoid = adjustmentFactorSigmoid
        self.weightPercentage = weightPercentage; self.tddAdjustBasal = tddAdjustBasal
        self.enableSMBAlways = enableSMBAlways; self.enableSMBWithCOB = enableSMBWithCOB
        self.enableSMBWithTemptarget = enableSMBWithTemptarget; self.enableSMBAfterCarbs = enableSMBAfterCarbs
        self.enableSMBHighBG = enableSMBHighBG; self.enableSMBHighBGTarget = enableSMBHighBGTarget
        self.enableUAM = enableUAM; self.maxSMBBasalMinutes = maxSMBBasalMinutes
        self.maxUAMSMBBasalMinutes = maxUAMSMBBasalMinutes; self.smbDeliveryRatio = smbDeliveryRatio
        self.maxDeltaBGThreshold = maxDeltaBGThreshold
        self.highTemptargetRaisesSensitivity = highTemptargetRaisesSensitivity
        self.lowTemptargetLowersSensitivity = lowTemptargetLowersSensitivity
        self.sensitivityRaisesTarget = sensitivityRaisesTarget
        self.resistanceLowersTarget = resistanceLowersTarget
        self.halfBasalExerciseTarget = halfBasalExerciseTarget
        self.useFPUConversion = useFPUConversion
        self.individualAdjustmentFactor = individualAdjustmentFactor
        self.fpuDelay = fpuDelay; self.fpuInterval = fpuInterval
        self.smoothGlucose = smoothGlucose
    }
}

public enum GlucoseUnit: String, Codable { case mgdL = "mg/dL"; case mmolL = "mmol/L" }
public enum InsulinCurveType: String, Codable { case rapidActing = "rapid-acting"; case ultraRapid = "ultra-rapid"; case bilinear = "bilinear" }
public enum DynamicISFMode: String, Codable { case disabled; case logarithmic; case sigmoid }

public struct ScheduleEntry: Codable {
    public let time: String
    public let offsetMinutes: Int
    public let value: Decimal
}

// MARK: - Parsed Determination

public struct ParsedDetermination: Codable {
    public let timestamp: Date
    public let bg: Decimal?
    public let isf: Decimal?
    public let profileISF: Decimal?        // From reason: "ISF: X→Y" — X is profile, Y is effective
    public let sensitivityRatio: Decimal?
    public let iob: Decimal?
    public let cob: Decimal?
    public let deviation: Decimal?
    public let insulinReq: Decimal?
    public let rate: Decimal?
    public let units: Decimal?
    public let duration: Decimal?
    public let eventualBG: Int?
    public let minPredBG: Decimal?
    public let minGuardBG: Decimal?
    public let minDelta: Decimal?
    public let expectedDelta: Decimal?
    public let threshold: Decimal?
    public let carbRatio: Decimal?
    public let reason: String
    public let reasonAF: Decimal?
    public let reasonTDD: Decimal?
    public let reasonBasalRatio: Decimal?
    public let iobPredictions: [Int]?    // predictions.iob — 47 values at 5-min intervals (3.9h)
}

// MARK: - Core Data Bridge Factory

extension ParsedDetermination {
    /// Creates a `ParsedDetermination` from already-structured data (e.g. Core Data).
    /// Derives fields not stored as discrete columns (profileISF, deviation, reasonTDD,
    /// reasonAF, reasonBasalRatio, minPredBG, minGuardBG) from the `reason` string,
    /// using the same logic as the log file parser.
    ///
    /// - Parameters:
    ///   - timestamp:      Determination timestamp (`deliverAt` / `timestamp`)
    ///   - bg:             Current glucose (`glucose` column)
    ///   - isf:            Effective ISF used for dosing (`insulinSensitivity` column)
    ///   - sensitivityRatio: Autosens ratio (`sensitivityRatio` column)
    ///   - iob:            Insulin on board (`iob` column)
    ///   - cob:            Carbs on board (`cob` column, Int16 → Decimal)
    ///   - insulinReq:     Insulin requirement (`insulinReq` column)
    ///   - rate:           Temp basal rate (`rate` column)
    ///   - units:          SMB units delivered (`smbToDeliver` column)
    ///   - duration:       Temp basal duration (`duration` column)
    ///   - eventualBG:     Eventual BG prediction (`eventualBG` column)
    ///   - threshold:      Safety threshold (`threshold` column)
    ///   - carbRatio:      Carb ratio (`carbRatio` column)
    ///   - minDelta:       Min BG delta (`minDelta` column)
    ///   - expectedDelta:  Expected BG delta (`expectedDelta` column)
    ///   - reason:         Full reason string — source for all derived fields
    ///   - iobPredictions: IOB forecast array (from `forecasts` where `type == "iob"`,
    ///                     sorted by `ForecastValue.index`, values as `[Int]`)
    public static func fromRaw(
        timestamp: Date,
        bg: Decimal?,
        isf: Decimal?,
        sensitivityRatio: Decimal?,
        iob: Decimal?,
        cob: Decimal?,
        insulinReq: Decimal?,
        rate: Decimal?,
        units: Decimal?,
        duration: Decimal?,
        eventualBG: Int?,
        threshold: Decimal?,
        carbRatio: Decimal?,
        minDelta: Decimal?,
        expectedDelta: Decimal?,
        reason: String,
        iobPredictions: [Int]?
    ) -> ParsedDetermination {
        // Always extract profileISF from reason string — it is not a discrete Core Data column.
        // If isf is nil (older Trio versions), also recover effective ISF from reason.
        let isfFields = ReasonStringParser.extractISFFields(from: reason)
        let resolvedISF = isf ?? isfFields.effective

        return ParsedDetermination(
            timestamp: timestamp,
            bg: bg,
            isf: resolvedISF,
            profileISF: isfFields.profile,
            sensitivityRatio: sensitivityRatio,
            iob: iob,
            cob: cob,
            deviation: ReasonStringParser.extractDeviation(from: reason),
            insulinReq: insulinReq,
            rate: rate,
            units: units,
            duration: duration,
            eventualBG: eventualBG,
            minPredBG: ReasonStringParser.extractMinPredBG(from: reason),
            minGuardBG: ReasonStringParser.extractMinGuardBG(from: reason),
            minDelta: minDelta,
            expectedDelta: expectedDelta,
            threshold: threshold,
            carbRatio: carbRatio,
            reason: reason,
            reasonAF: ReasonStringParser.extractDecimal(from: reason, prefix: "AF: ",          terminator: ",;)"),
            reasonTDD: ReasonStringParser.extractDecimal(from: reason, prefix: "TDD: ",         terminator: " U"),
            reasonBasalRatio: ReasonStringParser.extractDecimal(from: reason, prefix: "Basal ratio: ", terminator: ",;)"),
            iobPredictions: iobPredictions
        )
    }
}

public struct ParsedLogContext: Codable {
    public let timestamp: Date
    public let uamImpact: Decimal?
    public let uamDuration: Decimal?
    public let dynamicISFActive: Bool
    public let dynamicRatio: Decimal?
    public let dynamicISFLimited: Bool
    public let overrideActive: Bool
    public let overridePercentage: Decimal?
    public let tempTargetActive: Bool
    public let tdd: Decimal?       // from "Weighted TDD: X U" in dynamic ratios log line
}

public struct LoopCycleData: Codable {
    public let determination: ParsedDetermination
    public let context: ParsedLogContext?

    public init(determination: ParsedDetermination, context: ParsedLogContext?) {
        self.determination = determination
        self.context = context
    }

    public var isUAMActive: Bool {
        determination.reason.contains("UAMpredBG") ||
        (context?.uamDuration ?? 0) > 0
    }
}

// MARK: - Analysis Structures

public struct WindowClassification: Codable {
    public let cycle: LoopCycleData
    public let isCleanForBasal: Bool
    public let isCleanForISF: Bool
    public let isCleanForCR: Bool
    public let exclusionReasons: [String]
}

public struct TimeBlockAnalysis: Codable {
    public let blockLabel: String
    public let startMinutes: Int
    public let endMinutes: Int
    public let cleanDataPoints: Int
    public let totalDataPoints: Int
    public let medianDeviation: Decimal
    public let meanDeviation: Decimal
    public let deviationP25: Decimal
    public let deviationP75: Decimal
    public let medianSensitivityRatio: Decimal
    public let sensitivityRatioAtMax: Int
    public let sensitivityRatioAtMin: Int
    public let currentProfileValue: Decimal
    public let suggestedValue: Decimal?
    public let adjustmentPercent: Decimal?
}

public struct MealEvent: Codable {
    public let mealStartTime: Date
    public let mealEndTime: Date
    public let startBG: Decimal
    public let endBG: Decimal
    public let startIOB: Decimal
    public let endIOB: Decimal
    public let carbsEntered: Decimal
    public let totalInsulinDelivered: Decimal
    public let effectiveCR: Decimal?
    public let hasFPUTail: Bool
}

// MARK: - Output

public enum ConfidenceLevel: String, Codable, Comparable {
    case high, moderate, low, insufficient
    public static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool {
        let order: [ConfidenceLevel] = [.insufficient, .low, .moderate, .high]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// What to adjust. Logarithmic users get AF recommendations, not ISF.
public enum SettingPriority: String, Codable {
    case basal
    case isf                // Profile ISF (static or sigmoid)
    case adjustmentFactor   // AF (logarithmic)
    case cr
}

public enum AFDirection: String, Codable {
    case increase   // AF too low, ratio wanting to exceed autosens_max
    case decrease   // AF too high, ratio wanting to go below autosens_min
}

public struct SettingRecommendation: Codable {
    public let setting: SettingPriority
    public let timeBlockLabel: String
    public let currentValue: Decimal
    public let suggestedValue: Decimal?
    public let adjustmentPercent: Decimal?
    public let uncappedAdjustmentPercent: Decimal?
    public let confidence: ConfidenceLevel
    public let cleanDataPoints: Int
    public let rationale: String
}

public struct SettingScore: Codable {
    public let setting: SettingPriority
    public let score: Decimal
    public let needsAdjustment: Bool
    public let confidence: ConfidenceLevel
    public let limitHitPercentage: Decimal
    public let cleanDataPointsTotal: Int
    public let timeBlockAnalyses: [TimeBlockAnalysis]
    public let isAFRecommendation: Bool
    public let afDirection: AFDirection?
    public let medianTDD: Decimal?
    public let suggestedAF: Decimal?          // Empirically derived AF target (logarithmic only)
    public let tddCoefficientOfVariation: Decimal?  // CoV of TDD over data period (nil = not enough data)
    public let tddTrend: TDDTrend?            // Whether TDD is stable, rising, or falling

    /// Convenience initializer for non-logarithmic scores
    public init(setting: SettingPriority, score: Decimal, needsAdjustment: Bool,
         confidence: ConfidenceLevel, limitHitPercentage: Decimal,
         cleanDataPointsTotal: Int, timeBlockAnalyses: [TimeBlockAnalysis]) {
        self.setting = setting; self.score = score; self.needsAdjustment = needsAdjustment
        self.confidence = confidence; self.limitHitPercentage = limitHitPercentage
        self.cleanDataPointsTotal = cleanDataPointsTotal; self.timeBlockAnalyses = timeBlockAnalyses
        self.isAFRecommendation = false; self.afDirection = nil; self.medianTDD = nil
        self.suggestedAF = nil; self.tddCoefficientOfVariation = nil; self.tddTrend = nil
    }

    /// Full initializer for logarithmic scores
    public init(setting: SettingPriority, score: Decimal, needsAdjustment: Bool,
         confidence: ConfidenceLevel, limitHitPercentage: Decimal,
         cleanDataPointsTotal: Int, timeBlockAnalyses: [TimeBlockAnalysis],
         isAFRecommendation: Bool, afDirection: AFDirection?, medianTDD: Decimal?,
         suggestedAF: Decimal? = nil,
         tddCoefficientOfVariation: Decimal? = nil,
         tddTrend: TDDTrend? = nil) {
        self.setting = setting; self.score = score; self.needsAdjustment = needsAdjustment
        self.confidence = confidence; self.limitHitPercentage = limitHitPercentage
        self.cleanDataPointsTotal = cleanDataPointsTotal; self.timeBlockAnalyses = timeBlockAnalyses
        self.isAFRecommendation = isAFRecommendation; self.afDirection = afDirection
        self.medianTDD = medianTDD; self.suggestedAF = suggestedAF
        self.tddCoefficientOfVariation = tddCoefficientOfVariation; self.tddTrend = tddTrend
    }
}

public enum TDDTrend: String, Codable {
    case stable       // CoV < 15%, no significant first-half vs second-half shift
    case rising       // Second-half TDD meaningfully higher than first-half (> 15% difference)
    case falling      // Second-half TDD meaningfully lower than first-half (> 15% difference)
    case volatile     // CoV ≥ 25% — too variable to draw conclusions from median alone
}

public struct DetectedUserType: Codable {
    public let hasCarbEntries: Bool
    public let hasFPUEntries: Bool
    public let hasManualBoluses: Bool
    public let medianCarbEntrySize: Decimal?
    public let uamActivePercentage: Decimal
    public let inferredType: MealHandlingType
    public let agreesWithUserReport: Bool
    public let disagreementNote: String?
}

public struct GlycemicMetrics: Codable {
    /// % of readings with BG 70–180 mg/dL (standard time in range)
    public let timeInRange: Decimal
    /// % of readings with BG 70–140 mg/dL (tight range)
    public let timeInTightRange: Decimal
    /// % of readings with BG <70 mg/dL
    public let timeBelowRange: Decimal
    /// % of readings with BG >180 mg/dL
    public let timeAboveRange: Decimal
    /// Median BG across all readings, always in mg/dL
    public let medianGlucose: Decimal
    /// Number of BG readings used (one per loop cycle, ~every 5 min)
    public let bgReadingCount: Int
}

public struct AnalysisReport: Codable {
    public let analysisDate: Date
    public let dataRangeStart: Date
    public let dataRangeEnd: Date
    public let totalLoopCycles: Int
    public let settingsTimestamp: Date?
    public let userProfile: UserProfile
    public let detectedUserType: DetectedUserType
    public let dynamicISFMode: DynamicISFMode
    public let glycemicMetrics: GlycemicMetrics?
    public let basalScore: SettingScore
    public let isfScore: SettingScore
    public let crScore: SettingScore?
    public let prioritySetting: SettingPriority?
    public let recommendations: [SettingRecommendation]
    public let mealEvents: [MealEvent]?
    public let warnings: [AnalysisWarning]
}

public struct AnalysisWarning: Codable {
    public let severity: WarningSeverity
    public let message: String
}

public enum WarningSeverity: String, Codable { case info; case caution; case critical }

// MARK: - Known Version Issues

public enum KnownVersionIssues {
    /// ISF, deviation, BGI missing from JSON; extract from reason string
    public static let missingDeterminationFields: Set<String> = ["0.6.0.60"]
    /// No standalone "UAM Impact:" log lines; infer from reason string
    public static let missingUAMLogLines: Set<String> = ["0.6.0.60"]
}

// MARK: - Thresholds

public enum AnalysisThresholds {
    /// Minimum DIA (hours) for reliable IOB/analysis — exponential model requires 9–10h
    public static let minimumDIA: Decimal = 7
    /// Basal: median deviation magnitude (mg/dL/30m) to flag
    public static let basalDeviationMagnitude: Decimal = 10.0
    /// ISF (static): ratio bias from 1.0 to flag
    public static let isfRatioBias: Decimal = 0.10
    /// Logarithmic: % of cycles hitting autosens limits to flag AF
    public static let logLimitHitAlarmPercent: Decimal = 25.0
    /// CR: coefficient of variation threshold for counting inconsistency
    public static let crVarianceThreshold: Decimal = 0.40
    /// Minimum clean data points per time block
    public static let minimumDataPointsPerBlock: Int = 6
    /// Minimum total clean data points for any setting
    public static let minimumTotalDataPoints: Int = 24
    /// Minimum meal events for CR analysis
    public static let minimumMealEvents: Int = 4
    /// Maximum single-iteration adjustment cap
    public static let maxAdjustmentPercent: Decimal = 20.0
    /// Post-UAM stability minutes before ISF window is clean
    public static let postUAMStabilityMinutes: Int = 45
    /// Logarithmic: minimum AF fractional difference (from formula) to flag adjustment
    public static let afAdjustmentThreshold: Decimal = 0.10
}
