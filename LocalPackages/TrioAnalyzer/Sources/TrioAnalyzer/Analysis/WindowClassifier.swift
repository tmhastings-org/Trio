import Foundation

protocol WindowClassifier {
    func classify(cycles: [LoopCycleData], settings: TrioSettingsProfile, userType: DetectedUserType) -> [WindowClassification]
}

struct TrioWindowClassifier: WindowClassifier {
    func classify(cycles: [LoopCycleData], settings: TrioSettingsProfile, userType: DetectedUserType) -> [WindowClassification] {
        var results: [WindowClassification] = []
        let avgBasal = settings.basalRates.isEmpty ? Decimal(0.5)
            : settings.basalRates.map(\.value).reduce(0, +) / Decimal(settings.basalRates.count)

        for (index, cycle) in cycles.enumerated() {
            let det = cycle.determination
            let ctx = cycle.context
            var basalR: [String] = [], isfR: [String] = [], crR: [String] = []

            // Common exclusions
            if ctx?.overrideActive == true || det.reason.contains("Override active") {
                let r = "Override active"
                basalR.append(r)
                isfR.append(r)
                crR.append(r)
            }
            if det.reason.lowercased().contains("temptarget") {
                let r = "Temp target active"
                basalR.append(r)
                isfR.append(r)
            }
            if let bg = det.bg, bg <= 10 || bg == 38 {
                let r = "CGM error"
                basalR.append(r)
                isfR.append(r)
                crR.append(r)
            }
            if det.reason.contains("CGM is calibrating") || det.reason.contains("CGM data is unchanged") {
                let r = "CGM data issue"
                basalR.append(r)
                isfR.append(r)
                crR.append(r)
            }

            // Basal: low IOB, no COB, no UAM
            if (det.cob ?? 0) > 0 { basalR.append("COB > 0") }
            if cycle.isUAMActive { basalR.append("UAM active") }
            if let iob = det.iob, abs(iob) > avgBasal * Decimal(1.5) { basalR.append("IOB too high") }

            // Post-UAM stability for no-carb and manual-bolus users
            if userType.inferredType == .noEntry || userType.inferredType == .manualBolusOnly {
                if wasRecentlyUAM(index: index, cycles: cycles, minutes: AnalysisThresholds.postUAMStabilityMinutes) {
                    basalR.append("Post-UAM stability window")
                }
            }

            // ISF: meaningful IOB, no COB, no active UAM
            // Note: no post-UAM stability window here — UAMpredBG fires whenever IOB > 2× basal,
            // not only during meal absorption, so a trailing window would wipe out most clean data.
            // Point-in-time exclusion of active UAM cycles is sufficient.
            if (det.cob ?? 0) > 0 { isfR.append("COB > 0") }
            if cycle.isUAMActive { isfR.append("UAM active") }
            if let iob = det.iob, abs(iob) < avgBasal * Decimal(0.5) { isfR.append("IOB too low for ISF") }

            // CR: needs COB present
            if (det.cob ?? 0) == 0 { crR.append("No COB") }

            results.append(WindowClassification(
                cycle: cycle, isCleanForBasal: basalR.isEmpty,
                isCleanForISF: isfR.isEmpty, isCleanForCR: crR.isEmpty,
                exclusionReasons: Array(Set(basalR + isfR + crR))
            ))
        }
        return results
    }

    private func wasRecentlyUAM(index: Int, cycles: [LoopCycleData], minutes: Int) -> Bool {
        let current = cycles[index].determination.timestamp
        let windowStart = current.addingTimeInterval(-Double(minutes) * 60)
        var i = index - 1
        while i >= 0 {
            if cycles[i].determination.timestamp < windowStart { break }
            if cycles[i].isUAMActive { return true }
            i -= 1
        }
        return false
    }
}
