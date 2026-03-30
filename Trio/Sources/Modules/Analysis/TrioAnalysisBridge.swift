import CoreData
import Foundation
import LoopKit
import Swinject
import TrioAnalyzer

/// Builds `LoopCycleData` and `TrioSettingsProfile` from Trio's live data sources.
///
/// This is the integration layer between Trio's storage stack and TrioAnalyzerKit.
/// It owns all Core Data fetching and `SettingsManager` → `TrioSettingsProfile` mapping
/// so that TrioAnalyzerKit itself remains free of Trio-specific dependencies.
final class TrioAnalysisBridge: Injectable {

    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var deviceManager: DeviceDataManager!

    private let context: NSManagedObjectContext

    init(resolver: Resolver, context: NSManagedObjectContext? = nil) {
        self.context = context ?? CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
    }

    // MARK: - Cycles

    /// Fetches the last 48 hours of OrefDetermination records from Core Data and converts
    /// them into `LoopCycleData` values ready for TrioAnalyzerKit.
    ///
    /// IOB prediction arrays are prefetched via `relationshipKeyPathsForPrefetching`
    /// to avoid N+1 queries.
    func buildCycles() async -> [LoopCycleData] {
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let predicate = NSPredicate(format: "deliverAt >= %@", cutoff as NSDate)

        let request = OrefDetermination.fetchRequest()
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
        request.relationshipKeyPathsForPrefetching = ["forecasts.forecastValues"]

        do {
            let results: [OrefDetermination] = try await context.perform {
                try self.context.fetch(request)
            }
            return await context.perform {
                results.compactMap { self.cycleData(from: $0) }
            }
        } catch {
            debugPrint("TrioAnalysisBridge: fetch failed — \(error)")
            return []
        }
    }

    // MARK: - Settings

    /// Builds a `TrioSettingsProfile` from live SettingsManager and FileStorage values.
    /// Returns nil only when mandatory schedule data is missing.
    func buildSettings() -> TrioSettingsProfile? {
        let prefs = settingsManager.preferences
        let pump = settingsManager.pumpSettings
        let trio = settingsManager.settings

        guard
            let basalProfile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self),
            !basalProfile.isEmpty
        else { return nil }

        let isfContainer = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
        let crContainer = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
        let bgContainer = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)

        let insulinName: String
        if let pumpManager = deviceManager.pumpManager,
           let insulinType = pumpManager.status.insulinType {
            insulinName = insulinType.title
        } else {
            insulinName = prefs.curve.rawValue
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        return TrioSettingsProfile(
            exportDate: Date(),
            appVersion: appVersion,
            glucoseUnits: trio.units == .mgdL ? .mgdL : .mmolL,
            basalRates: basalProfile.map {
                ScheduleEntry(time: $0.start, offsetMinutes: $0.minutes, value: $0.rate)
            },
            isfSchedule: isfContainer?.sensitivities.map {
                ScheduleEntry(time: $0.start, offsetMinutes: $0.offset, value: $0.sensitivity)
            } ?? [],
            crSchedule: crContainer?.schedule.map {
                ScheduleEntry(time: $0.start, offsetMinutes: $0.offset, value: $0.ratio)
            } ?? [],
            glucoseTargets: bgContainer?.targets.map {
                ScheduleEntry(time: $0.start, offsetMinutes: $0.offset, value: $0.low)
            } ?? [],
            maxIOB: prefs.maxIOB,
            maxBolus: pump.maxBolus,
            maxBasalRate: pump.maxBasal,
            maxCOB: prefs.maxCOB,
            threshold: prefs.threshold_setting,
            insulinCurve: insulinCurve(from: prefs.curve),
            insulinName: insulinName,
            dia: pump.insulinActionCurve,
            useCustomPeakTime: prefs.useCustomPeakTime,
            insulinPeakTime: prefs.insulinPeakTime,
            autosensMax: prefs.autosensMax,
            autosensMin: prefs.autosensMin,
            dynamicISFMode: dynamicISFMode(from: prefs),
            adjustmentFactor: prefs.adjustmentFactor,
            adjustmentFactorSigmoid: prefs.adjustmentFactorSigmoid,
            weightPercentage: prefs.weightPercentage,
            tddAdjustBasal: prefs.tddAdjBasal,
            enableSMBAlways: prefs.enableSMBAlways,
            enableSMBWithCOB: prefs.enableSMBWithCOB,
            enableSMBWithTemptarget: prefs.enableSMBWithTemptarget,
            enableSMBAfterCarbs: prefs.enableSMBAfterCarbs,
            enableSMBHighBG: prefs.enableSMB_high_bg,
            enableSMBHighBGTarget: prefs.enableSMB_high_bg_target,
            enableUAM: prefs.enableUAM,
            maxSMBBasalMinutes: prefs.maxSMBBasalMinutes,
            maxUAMSMBBasalMinutes: prefs.maxUAMSMBBasalMinutes,
            smbDeliveryRatio: prefs.smbDeliveryRatio,
            maxDeltaBGThreshold: prefs.maxDeltaBGthreshold,
            highTemptargetRaisesSensitivity: prefs.highTemptargetRaisesSensitivity,
            lowTemptargetLowersSensitivity: prefs.lowTemptargetLowersSensitivity,
            sensitivityRaisesTarget: prefs.sensitivityRaisesTarget,
            resistanceLowersTarget: prefs.resistanceLowersTarget,
            halfBasalExerciseTarget: prefs.halfBasalExerciseTarget,
            useFPUConversion: trio.useFPUconversion,
            individualAdjustmentFactor: trio.individualAdjustmentFactor,
            fpuDelay: trio.delay,
            fpuInterval: trio.minuteInterval,
            smoothGlucose: trio.smoothGlucose
        )
    }

    // MARK: - Private helpers

    private func cycleData(from det: OrefDetermination) -> LoopCycleData? {
        guard let timestamp = det.deliverAt ?? det.timestamp else { return nil }
        let reason = det.reason ?? ""

        let iobPredictions: [Int]? = det.forecasts
            .flatMap { forecastSet -> [Int]? in
                guard let iobForecast = forecastSet.first(where: { $0.type == "iob" }),
                      let values = iobForecast.forecastValues
                else { return nil }
                return values.sorted(by: { $0.index < $1.index }).map { Int($0.value) }
            }

        let determination = ParsedDetermination.fromRaw(
            timestamp: timestamp,
            bg: det.glucose?.decimalValue,
            isf: det.insulinSensitivity?.decimalValue,
            sensitivityRatio: det.sensitivityRatio?.decimalValue,
            iob: det.iob?.decimalValue,
            cob: Decimal(det.cob),
            insulinReq: det.insulinReq?.decimalValue,
            rate: det.rate?.decimalValue,
            units: det.smbToDeliver?.decimalValue,
            duration: det.duration?.decimalValue,
            eventualBG: det.eventualBG.map { Int(truncating: $0) },
            threshold: det.threshold?.decimalValue,
            carbRatio: det.carbRatio?.decimalValue,
            minDelta: det.minDelta?.decimalValue,
            expectedDelta: det.expectedDelta?.decimalValue,
            reason: reason,
            iobPredictions: iobPredictions
        )

        return LoopCycleData(determination: determination, context: nil)
    }

    private func insulinCurve(from curve: InsulinCurve) -> InsulinCurveType {
        switch curve {
        case .rapidActing: return .rapidActing
        case .ultraRapid:  return .ultraRapid
        case .bilinear:    return .bilinear
        }
    }

    private func dynamicISFMode(from prefs: Preferences) -> DynamicISFMode {
        guard prefs.useNewFormula else { return .disabled }
        return prefs.sigmoid ? .sigmoid : .logarithmic
    }
}
