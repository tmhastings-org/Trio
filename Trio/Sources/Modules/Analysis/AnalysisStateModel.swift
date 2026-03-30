import Observation
import SwiftUI
import TrioAnalyzer

extension Analysis {
    @Observable final class StateModel: BaseStateModel<Provider> {

        // MARK: - User inputs (bound to onboarding UI before running)

        var mealHandling: MealHandlingType = .varies
        var carbCounting: CarbCountingConfidence = .notApplicable

        // MARK: - Analysis state

        var report: AnalysisReport?
        var isRunning = false
        var errorMessage: String?

        // MARK: - Bridge

        private var bridge: TrioAnalysisBridge?

        override func subscribe() {
            if let resolver = resolver {
                bridge = TrioAnalysisBridge(resolver: resolver)
            }
        }

        // MARK: - Run analysis

        func run() {
            guard !isRunning else { return }
            isRunning = true
            errorMessage = nil
            report = nil

            Task { [weak self] in
                guard let self else { return }
                await self.performAnalysis()
            }
        }

        @MainActor
        private func performAnalysis() async {
            defer { isRunning = false }

            guard let bridge else {
                errorMessage = String(localized: "Analysis bridge unavailable.")
                return
            }

            guard let settings = bridge.buildSettings() else {
                errorMessage = String(localized: "Could not read Trio settings.")
                return
            }

            let cycles = await bridge.buildCycles()

            let result = TrioAnalyzerKit.analyze(
                cycles: cycles,
                settings: settings,
                mealHandling: mealHandling,
                carbCounting: carbCounting
            )

            // Surface any critical warnings as the top-level error message
            if let critical = result.warnings.first(where: { $0.severity == .critical }) {
                errorMessage = critical.message
            }

            report = result
        }
    }
}
