import SwiftUI

/// The flood tools' options (spec 0016, PRD T-4/APP-4/TOOL-C; 0017 reuses the view with
/// `.paintBucket`), Paint.NET's controls left to right: the **Flood mode** segmented
/// picker (Contiguous / Global, Shift-click forces Global), **Tolerance:** (slider
/// 0–100 with a `NN%` readout, monospaced digits, arrow keys step 1; identifier
/// `toolOptions.tolerance` on the slider — a SwiftUI Slider vends its *numeric*
/// accessibility value, the string discovery spec 0007 recorded, and the "NN%" string
/// is the trailing readout), and **Sampling** (Layer / Image — the same identifier as
/// 0012's Color Picker; only one tool's bar is visible at a time). Values persist under
/// `tool.<tool>.{tolerance,floodMode,samplingMode}` (TOOL-C) and the view observes
/// `toolOptions.revision` like the others.
struct FloodToolOptionsView: View {
    let model: AppModel
    let tool: ToolID

    private var floodMode: FloodMode {
        _ = model.toolOptions.revision
        return model.toolOptions.value(FloodToolOptions.floodMode(for: tool))
    }

    private var tolerance: Int {
        _ = model.toolOptions.revision
        return model.toolOptions.value(FloodToolOptions.tolerance(for: tool))
    }

    private var samplingMode: SamplingMode {
        _ = model.toolOptions.revision
        return model.toolOptions.value(FloodToolOptions.samplingMode(for: tool))
    }

    private func setTolerance(_ value: Int) {
        model.toolOptions.setValue(Swift.min(Swift.max(value, 0), 100),
                                   for: FloodToolOptions.tolerance(for: tool))
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Flood mode", selection: Binding(
                get: { floodMode },
                set: { model.toolOptions.setValue($0, for: FloodToolOptions.floodMode(for: tool)) }
            )) {
                ForEach(FloodMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Flood mode (Shift-click for Global)")
            .accessibilityIdentifier("toolOptions.floodMode")
            .accessibilityLabel("Flood mode")
            .accessibilityValue(floodMode.displayName)

            // `toolOptions.tolerance` sits on the native slider (the spec's layout);
            // a SwiftUI Slider vends its numeric AX value — the "NN%" string lives in
            // the trailing readout (spec 0007's recorded slider discovery).
            HStack(spacing: 4) {
                Text("Tolerance:")
                Slider(value: Binding(
                    get: { Double(tolerance) },
                    set: { setTolerance(Int($0.rounded())) }
                ), in: 0...100, step: 1)
                .frame(width: 110)
                .labelsHidden()
                .help("Tolerance")
                .accessibilityIdentifier("toolOptions.tolerance")
                .accessibilityLabel("Tolerance")
                Text("\(tolerance)%")
                    .monospacedDigit()
            }

            Picker("Sampling", selection: Binding(
                get: { samplingMode },
                set: { model.toolOptions.setValue($0,
                                                  for: FloodToolOptions.samplingMode(for: tool)) }
            )) {
                ForEach(SamplingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Sampling")
            .accessibilityIdentifier("toolOptions.samplingMode")
            .accessibilityLabel("Sampling")
            .accessibilityValue(samplingMode.displayName)
        }
    }
}
