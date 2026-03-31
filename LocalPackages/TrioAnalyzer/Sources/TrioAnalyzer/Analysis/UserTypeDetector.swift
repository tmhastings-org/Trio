import Foundation

protocol UserTypeDetector {
    func detect(cycles: [LoopCycleData], settings: TrioSettingsProfile, userReport: MealHandlingType) -> DetectedUserType
}

struct TrioUserTypeDetector: UserTypeDetector {
    func detect(cycles: [LoopCycleData], settings: TrioSettingsProfile, userReport: MealHandlingType) -> DetectedUserType {
        guard !cycles.isEmpty else {
            return DetectedUserType(
                hasCarbEntries: false,
                hasFPUEntries: false,
                hasManualBoluses: false,
                medianCarbEntrySize: nil,
                uamActivePercentage: 0,
                inferredType: userReport,
                agreesWithUserReport: true,
                disagreementNote: nil
            )
        }

        let hasCarbEntries = cycles.contains { ($0.determination.cob ?? 0) > 0 }
        let hasFPU = detectFPUPattern(cycles) && settings.useFPUConversion
        let hasManualBoluses = detectManualBoluses(cycles)
        let medianCarb = computeMedianCarbEntry(cycles)
        let uamPct = Decimal(cycles.filter(\.isUAMActive).count) / Decimal(max(cycles.count, 1)) * 100

        let inferred = inferType(hasCarbEntries: hasCarbEntries, hasFPU: hasFPU, hasManualBoluses: hasManualBoluses)
        let (agrees, note) = compare(inferred: inferred, reported: userReport, hasCarbEntries: hasCarbEntries)

        return DetectedUserType(
            hasCarbEntries: hasCarbEntries,
            hasFPUEntries: hasFPU,
            hasManualBoluses: hasManualBoluses,
            medianCarbEntrySize: medianCarb,
            uamActivePercentage: uamPct,
            inferredType: inferred,
            agreesWithUserReport: agrees,
            disagreementNote: note
        )
    }

    private func detectFPUPattern(_ cycles: [LoopCycleData]) -> Bool {
        var inCOB = false
        var depleted = false
        var secondary = 0
        for c in cycles {
            let cob = c.determination.cob ?? 0
            if cob > 0 { if depleted { secondary += 1
                depleted = false }
            inCOB = true } else if inCOB { depleted = true
                inCOB = false }
        }
        return secondary >= 2
    }

    private func detectManualBoluses(_ cycles: [LoopCycleData]) -> Bool {
        var count = 0
        for i in 1 ..< cycles.count {
            let prevIOB = cycles[i - 1].determination.iob ?? 0
            let currIOB = cycles[i].determination.iob ?? 0
            let smb = cycles[i - 1].determination.units ?? 0
            if (currIOB - prevIOB - smb) > Decimal(0.5) { count += 1 }
        }
        return count >= 2
    }

    private func computeMedianCarbEntry(_ cycles: [LoopCycleData]) -> Decimal? {
        var peaks: [Decimal] = []
        var peak: Decimal = 0
        var inMeal = false
        for c in cycles {
            let cob = c.determination.cob ?? 0
            if cob > 0 { peak = max(peak, cob)
                inMeal = true } else if inMeal { if peak > 0 { peaks.append(peak) }
                peak = 0
                inMeal = false }
        }
        if inMeal, peak > 0 { peaks.append(peak) }
        guard !peaks.isEmpty else { return nil }
        let s = peaks.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    private func inferType(hasCarbEntries: Bool, hasFPU: Bool, hasManualBoluses: Bool) -> MealHandlingType {
        if !hasCarbEntries, !hasManualBoluses { return .noEntry }
        if !hasCarbEntries, hasManualBoluses { return .manualBolusOnly }
        if hasCarbEntries, hasFPU { return .carbsFatProtein }
        if hasCarbEntries { return .carbsOnly }
        return .varies
    }

    private func compare(inferred: MealHandlingType, reported: MealHandlingType, hasCarbEntries _: Bool) -> (Bool, String?) {
        if reported == .varies { return (true, nil) }
        if inferred == reported { return (true, nil) }

        switch (reported, inferred) {
        case (.carbsFatProtein, .noEntry),
             (.carbsOnly, .noEntry):
            return (
                false,
                "You indicated you enter carbs, but none were found in this period. Consider re-exporting after a typical 48-hour window."
            )
        case (.noEntry, .carbsFatProtein),
             (.noEntry, .carbsOnly):
            return (false, "You indicated no carb entries, but carbs were detected. Analysis uses the detected pattern.")
        default:
            return (
                false,
                "Detected (\(inferred.rawValue)) differs from reported (\(reported.rawValue)). Analysis uses detected pattern."
            )
        }
    }
}
