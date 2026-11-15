import SwiftUI

/// The Colors panel (PRD §5.10 C-1/C-2, D-20; spec 0007): the primary/secondary swatches with
/// swap and reset, the color wheel, and — under `More »` — the hex box and the seven
/// RGB/HSV/Alpha sliders. Paint.NET's Colors window drawn by hand: `NSColorPanel` is explicitly
/// not used (D-20). AppKit's `Window` ⇧⌥⌘4 item opens it through `PanelController`.
struct ColorsPanelView: View {
    let model: AppModel
    /// The hex and numeric boxes' editing state, so a test can commit or cancel exactly as
    /// Return and Escape do.
    let fields: ColorsPanelFields

    @MainActor
    init(model: AppModel, fields: ColorsPanelFields = ColorsPanelFields()) {
        self.model = model
        self.fields = fields
    }

    static let wheelDiameter: CGFloat = 160
    static let contentWidth: CGFloat = 176
    private static let padding: CGFloat = 8
    private static let sectionSpacing: CGFloat = 8
    private static let rowSpacing: CGFloat = 6
    private static let swatchSide: CGFloat = 28
    private static let swatchOffset: CGFloat = 12
    private static let resetIconSide: CGFloat = 14
    private static let hexFieldWidth: CGFloat = 96
    private static let channelLabelWidth: CGFloat = 14
    private static let fieldWidth: CGFloat = 44
    private static let sliderHeight: CGFloat = 14
    /// Gradient samples per track; the gradient is an approximation of the channel's effect.
    private static let gradientStops = 8

    private var swatchPairSide: CGFloat { Self.swatchSide + Self.swatchOffset }

    /// Which text box has focus, so leaving it commits and entering it clears for typing.
    private enum EditableField: Hashable {
        case hex
        case channel(ColorChannel)
    }

    @FocusState private var focusedField: EditableField?

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            ColorWheelView(model: model)
                .frame(width: Self.wheelDiameter, height: Self.wheelDiameter)
                .frame(maxWidth: .infinity, alignment: .center)
            if model.colorsPanelExpanded {
                hexRow
                sliders
            }
            moreLessButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Self.padding)
        .frame(width: Self.contentWidth)
        .onChange(of: focusedField) { leaving, entering in
            switch leaving {
            case .hex: fields.commitHex(in: model)
            case .channel(let channel): fields.commit(channel, in: model)
            case nil: break
            }
            switch entering {
            case .hex: fields.beginHexEdit()
            case .channel(let channel): fields.beginEdit(channel)
            case nil: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("colorsPanel")
    }

    // MARK: - Swatches, swap, reset (C-1)

    private var header: some View {
        HStack(alignment: .top, spacing: Self.rowSpacing) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                swatchPair
                resetButton
            }
            swapButton
            Spacer(minLength: 0)
        }
    }

    /// Paint.NET's overlapping pair: primary upper-left, secondary lower-right.
    private var swatchPair: some View {
        ZStack(alignment: .topLeading) {
            swatch(.secondary)
                .offset(x: Self.swatchOffset, y: Self.swatchOffset)
            swatch(.primary)
        }
        .frame(width: swatchPairSide, height: swatchPairSide)
    }

    private func swatch(_ slot: ColorSlot) -> some View {
        Button { model.setActiveColorSlot(slot) } label: {
            ColorSwatch(color: model.colors[slot], isActive: model.activeColorSlot == slot)
        }
        .buttonStyle(.plain)
        .frame(width: Self.swatchSide, height: Self.swatchSide)
        .accessibilityLabel(slot.accessibilityLabel)
        .accessibilityValue(ColorHex.format(model.colors[slot], includeAlpha: true))
        .accessibilityIdentifier(slot.swatchIdentifier)
        .accessibilityAddTraits(model.activeColorSlot == slot ? .isSelected : [])
    }

    private var swapButton: some View {
        Button {
            model.swapColors()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
        }
        .buttonStyle(.borderless)
        .help("Swap Colors (X)")
        .accessibilityLabel("Swap colors")
        .accessibilityIdentifier("colors.swap")
    }

    private var resetButton: some View {
        Button {
            model.resetColors()
        } label: {
            DefaultColorsIcon()
                .frame(width: Self.resetIconSide, height: Self.resetIconSide)
        }
        .buttonStyle(.borderless)
        .help("Reset to Default Colors (D)")
        .accessibilityLabel("Reset colors")
        .accessibilityIdentifier("colors.reset")
    }

    // MARK: - Hex and sliders (C-2)

    private var hexRow: some View {
        HStack(spacing: Self.rowSpacing) {
            Text("Hex")
            TextField("Hex", text: Binding(get: { fields.hexText(in: model) },
                                           set: { fields.typeHex($0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.hexFieldWidth)
                .focused($focusedField, equals: .hex)
                .accessibilityLabel(model.activeColorSlot == .primary ? "Primary color hex" : "Secondary color hex")
                .accessibilityIdentifier(ColorHex.fieldIdentifier)
                .onSubmit { fields.commitHex(in: model) }
                .onExitCommand { fields.cancelHex() }
            Spacer(minLength: 0)
        }
    }

    private var sliders: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(ColorChannel.allCases, id: \.self) { channel in
                sliderRow(channel)
            }
        }
    }

    private func sliderRow(_ channel: ColorChannel) -> some View {
        HStack(spacing: Self.rowSpacing) {
            Text(channel.shortLabel)
                .frame(width: Self.channelLabelWidth, alignment: .leading)
            ChannelSlider(label: channel.label, identifier: channel.sliderIdentifier,
                          range: channel.range,
                          stops: gradientStops(for: channel),
                          showsCheckerboard: channel == .alpha,
                          value: Binding(get: { Double(model.colorEditor.value(of: channel)) },
                                         set: { model.setColorChannel(channel, to: Int($0.rounded())) }))
                .frame(height: Self.sliderHeight)
            TextField(channel.label, text: Binding(get: { fields.text(for: channel, in: model) },
                                                  set: { fields.type($0, for: channel) }))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.fieldWidth)
                .focused($focusedField, equals: .channel(channel))
                .accessibilityLabel(channel.label)
                .accessibilityIdentifier(channel.fieldIdentifier)
                .onSubmit { fields.commit(channel, in: model) }
                .onExitCommand { fields.cancel(channel) }
        }
    }

    /// The track's gradient: the channel's own range with every other component fixed (C-2),
    /// computed by a probe copy of the pure editor state so a track can never disagree with what
    /// its slider does.
    private func gradientStops(for channel: ColorChannel) -> [Color] {
        var probe = model.colorEditor
        let span = channel.range.upperBound - channel.range.lowerBound
        return (0...Self.gradientStops).map { step in
            let value = channel.range.lowerBound
                + Int((Double(step) / Double(Self.gradientStops) * Double(span)).rounded())
            probe.set(channel, to: value)
            return Color(probe.selection[model.activeColorSlot])
        }
    }

    /// One stable identifier across both states (spec 0007: `colors.moreLess`). No explicit
    /// `accessibilityLabel`: the exact title (`More »` / `« Less`) is what VoiceOver reads.
    static let moreLessIdentifier = "colors.moreLess"

    private var moreLessButton: some View {
        Button(model.colorsPanelExpanded ? "« Less" : "More »") {
            model.setColorsPanelExpanded(!model.colorsPanelExpanded)
        }
        .accessibilityIdentifier(Self.moreLessIdentifier)
    }
}

/// The hex and numeric boxes' editing state (spec 0007). A box shows the model's value while it
/// is not being edited and what the user has typed while it is; Return and losing focus commit,
/// Escape and unparseable input revert. Focusing empties the hex box so typing replaces the
/// value, which is what Paint.NET's select-all-on-focus achieves.
@MainActor
@Observable
final class ColorsPanelFields {
    private var hexDraft: String?
    private var drafts: [ColorChannel: String] = [:]

    func hexText(in model: AppModel) -> String {
        hexDraft ?? ColorHex.displayString(model.colors[model.activeColorSlot])
    }

    func beginHexEdit() {
        hexDraft = ""
    }

    func typeHex(_ text: String) {
        hexDraft = text
    }

    func commitHex(in model: AppModel) {
        guard let draft = hexDraft else { return }
        hexDraft = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Bad hex keeps the current color and refreshes the box (C-2, Edge cases).
        model.applyHex(trimmed)
    }

    func cancelHex() {
        hexDraft = nil
    }

    func text(for channel: ColorChannel, in model: AppModel) -> String {
        drafts[channel] ?? String(model.colorEditor.value(of: channel))
    }

    func beginEdit(_ channel: ColorChannel) {
        drafts[channel] = ""
    }

    func type(_ text: String, for channel: ColorChannel) {
        drafts[channel] = text
    }

    func commit(_ channel: ColorChannel, in model: AppModel) {
        guard let draft = drafts[channel] else { return }
        drafts[channel] = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return }
        // Out-of-range input clamps to the channel's range (Edge cases).
        model.setColorChannel(channel, to: value)
    }

    func cancel(_ channel: ColorChannel) {
        drafts[channel] = nil
    }
}

/// One Colors-panel slider (C-2): a hand-drawn gradient track and thumb, so the track can show
/// what the channel does, exposed to accessibility as an adjustable slider whose increments run
/// through `AppModel.setColorChannel` by way of its binding.
private struct ChannelSlider: View {
    let label: String
    let identifier: String
    let range: ClosedRange<Int>
    let stops: [Color]
    var showsCheckerboard = false
    @Binding var value: Double

    private static let thumbDiameter: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let thumb = Self.thumbDiameter
            let travel = max(proxy.size.width - thumb, 0)
            ZStack(alignment: .leading) {
                if showsCheckerboard {
                    Checkerboard(squareSize: 3)
                        .clipShape(Capsule(style: .continuous))
                }
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1))
                    .frame(width: thumb, height: thumb)
                    .offset(x: Self.fraction(of: value, range: range) * travel)
            }
            .frame(height: thumb, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                value = Self.value(atX: gesture.location.x, width: proxy.size.width, thumb: thumb,
                                   range: range)
            })
        }
        // An adjustable element rather than `accessibilityRepresentation`, so the identifier,
        // label, and value are exactly what the panel promises (C-2).
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Text("\(Int(value.rounded()))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, Double(range.upperBound))
            case .decrement: value = max(value - 1, Double(range.lowerBound))
            @unknown default: break
            }
        }
    }

    static func fraction(of value: Double, range: ClosedRange<Int>) -> CGFloat {
        let span = Double(range.upperBound - range.lowerBound)
        guard span > 0 else { return 0 }
        let fraction = (min(max(value, Double(range.lowerBound)), Double(range.upperBound))
            - Double(range.lowerBound)) / span
        return CGFloat(fraction)
    }

    /// A pointer's x within the track: the thumb's centre is the value, so the ends read exactly
    /// as the range's ends.
    static func value(atX x: CGFloat, width: CGFloat, thumb: CGFloat,
                      range: ClosedRange<Int>) -> Double {
        let travel = max(width - thumb, 1)
        let fraction = min(max((Double(x) - Double(thumb) / 2) / Double(travel), 0), 1)
        return Double(range.lowerBound)
            + (fraction * Double(range.upperBound - range.lowerBound)).rounded()
    }
}

/// A primary/secondary swatch (C-1): the color over Paint.NET's checkerboard so alpha shows, with
/// the heavy outline on whichever slot is active.
private struct ColorSwatch: View {
    let color: ColorRGBA8
    var isActive = false

    private static let activeOutline: CGFloat = 2
    private static let inactiveOutline: CGFloat = 1

    var body: some View {
        ZStack {
            Checkerboard(squareSize: 3)
            Color(color)
        }
        .overlay(
            Rectangle().strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.35),
                                     lineWidth: isActive ? Self.activeOutline : Self.inactiveOutline)
        )
    }
}

/// The reset button's icon: Paint.NET's black-and-white squares.
private struct DefaultColorsIcon: View {
    var body: some View {
        Canvas { context, size in
            let edge = CGRect(origin: .zero, size: size)
            context.fill(Path(edge), with: .color(.white))
            var triangle = Path()
            triangle.move(to: .zero)
            triangle.addLine(to: CGPoint(x: size.width, y: 0))
            triangle.addLine(to: CGPoint(x: 0, y: size.height))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(.black))
            context.stroke(Path(edge.insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(.primary.opacity(0.4)), lineWidth: 1)
        }
    }
}

/// Paint.NET's transparency checkerboard, in the canvas compositor's own two grays (0003).
struct Checkerboard: View {
    var squareSize: CGFloat

    var body: some View {
        Canvas { context, size in
            let columns = Int((size.width / squareSize).rounded(.up))
            let rows = Int((size.height / squareSize).rounded(.up))
            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(x: CGFloat(column) * squareSize, y: CGFloat(row) * squareSize,
                                      width: squareSize, height: squareSize)
                    context.fill(Path(rect), with: .color(
                        (row + column).isMultiple(of: 2) ? Self.light : Self.dark))
                }
            }
        }
    }

    private static let standard = CheckerboardStyle.standard

    static let light = Color(standard.lightColor)
    static let dark = Color(standard.darkColor)
}

extension Color {
    /// The same 8-bit sRGB channel values, straight through to SwiftUI. Control chrome only —
    /// pixels stay `ColorRGBA8` (AGENTS.md rule 4).
    init(_ color: ColorRGBA8) {
        self.init(red: Double(color.red) / 255, green: Double(color.green) / 255,
                  blue: Double(color.blue) / 255, opacity: Double(color.alpha) / 255)
    }
}
