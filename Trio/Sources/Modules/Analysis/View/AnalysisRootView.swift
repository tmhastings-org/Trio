import SwiftUI
import Swinject
import TrioAnalyzer

extension Analysis {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                if let report = state.report {
                    reportSections(report)
                } else {
                    inputSection
                    runSection
                }
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle(String(localized: "Settings Analysis", comment: "Analysis tab title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if state.report != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "New Analysis", comment: "Reset analysis")) {
                            state.report = nil
                            state.errorMessage = nil
                        }
                    }
                }
            }
        }

        // MARK: - Input

        private var inputSection: some View {
            Section(header: Text("About You")) {
                Picker(
                    String(localized: "Meal Handling", comment: "Analysis input"),
                    selection: $state.mealHandling
                ) {
                    ForEach(MealHandlingType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }

                Picker(
                    String(localized: "Carb Counting Accuracy", comment: "Analysis input"),
                    selection: $state.carbCounting
                ) {
                    ForEach(CarbCountingConfidence.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        private var runSection: some View {
            Section {
                if state.isRunning {
                    HStack {
                        Spacer()
                        ProgressView(String(localized: "Analyzing…", comment: "Analysis progress"))
                        Spacer()
                    }
                } else {
                    if let error = state.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                    Button(String(localized: "Run Analysis", comment: "Analysis action")) {
                        state.run()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .disabled(state.isRunning)
                }
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Report

        @ViewBuilder
        private func reportSections(_ report: AnalysisReport) -> some View {
            // Warnings
            let criticalAndCaution = report.warnings.filter { $0.severity != .info }
            if !criticalAndCaution.isEmpty {
                Section(header: Text("Warnings")) {
                    ForEach(criticalAndCaution, id: \.message) { warning in
                        Label {
                            Text(warning.message).font(.footnote)
                        } icon: {
                            Image(systemName: warning.severity == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                .foregroundStyle(warning.severity == .critical ? .red : .orange)
                        }
                    }
                }
                .listRowBackground(Color.chart)
            }

            // Summary
            Section(header: Text("Summary")) {
                LabeledContent(
                    String(localized: "Data range", comment: "Analysis summary"),
                    value: dateRangeText(report)
                )
                LabeledContent(
                    String(localized: "Loop cycles", comment: "Analysis summary"),
                    value: "\(report.totalLoopCycles)"
                )
                LabeledContent(
                    String(localized: "Dynamic ISF mode", comment: "Analysis summary"),
                    value: report.dynamicISFMode.rawValue.capitalized
                )
                if let priority = report.prioritySetting {
                    LabeledContent(
                        String(localized: "Priority adjustment", comment: "Analysis summary"),
                        value: priority.rawValue.capitalized
                    )
                }
            }
            .listRowBackground(Color.chart)

            // Recommendations
            if !report.recommendations.isEmpty {
                Section(header: Text("Recommendations")) {
                    ForEach(report.recommendations, id: \.timeBlockLabel) { rec in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rec.setting.rawValue.capitalized + " · " + rec.timeBlockLabel)
                                    .font(.subheadline).bold()
                                Spacer()
                                confidenceBadge(rec.confidence)
                            }
                            if let suggested = rec.suggestedValue, let pct = rec.adjustmentPercent {
                                Text(
                                    "Current: \(rec.currentValue.formatted()) → Suggested: \(suggested.formatted()) (\(pct > 0 ? "+" : "")\(pct.formatted())%)"
                                )
                                .font(.footnote)
                            }
                            Text(rec.rationale)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Color.chart)
            } else {
                Section {
                    Text("No adjustments recommended based on available data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)
            }
        }

        // MARK: - Helpers

        private func dateRangeText(_ report: AnalysisReport) -> String {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            return fmt.string(from: report.dataRangeStart) + " – " + fmt.string(from: report.dataRangeEnd)
        }

        @ViewBuilder
        private func confidenceBadge(_ level: ConfidenceLevel) -> some View {
            Text(level.rawValue.capitalized)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(confidenceColor(level).opacity(0.2))
                .foregroundStyle(confidenceColor(level))
                .clipShape(Capsule())
        }

        private func confidenceColor(_ level: ConfidenceLevel) -> Color {
            switch level {
            case .high:         return .green
            case .moderate:     return .yellow
            case .low:          return .orange
            case .insufficient: return .red
            }
        }
    }
}

// MARK: - Display name helpers

private extension MealHandlingType {
    var displayName: String {
        switch self {
        case .noEntry:        return String(localized: "No meal entry", comment: "Meal handling type")
        case .manualBolusOnly: return String(localized: "Manual bolus only", comment: "Meal handling type")
        case .carbsOnly:      return String(localized: "Carbs only", comment: "Meal handling type")
        case .carbsFatProtein: return String(localized: "Carbs + fat & protein", comment: "Meal handling type")
        case .varies:         return String(localized: "Varies", comment: "Meal handling type")
        }
    }
}

private extension CarbCountingConfidence {
    var displayName: String {
        switch self {
        case .precise:       return String(localized: "Precise", comment: "Carb counting confidence")
        case .reasonable:    return String(localized: "Reasonable", comment: "Carb counting confidence")
        case .rough:         return String(localized: "Rough", comment: "Carb counting confidence")
        case .notApplicable: return String(localized: "Not applicable", comment: "Carb counting confidence")
        }
    }
}
