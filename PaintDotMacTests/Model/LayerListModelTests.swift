import Foundation
import Testing

@testable import PaintDotMac

/// `LayerListModel` (spec 0025 item 5): display-order rows, the enablement table (equal
/// to 0024's menu validation), the `List.onMove` → layer-index mapping, and the defensive
/// clamps.
struct LayerListModelTests {
    private func image(names: [String], visible: [Bool]? = nil,
                       opacity: [UInt8]? = nil, active: Int) -> LayeredImage {
        let size = PixelSize(width: 8, height: 8)
        let layers = names.enumerated().map { index, name in
            Layer(name: name, surface: TiledSurface(size: size),
                  isVisible: visible?[index] ?? true,
                  opacity: opacity?[index] ?? 255)
        }
        return LayeredImage(size: size, layers: layers, activeLayerIndex: active)
    }

    @Test func rowsAreTopFirst() {
        let model = LayerListModel(image: image(names: ["A", "B", "C"],
                                                visible: [true, false, true], active: 1))
        #expect(model.rows.map(\.name) == ["C", "B", "A"])
        #expect(model.rows.map(\.index) == [2, 1, 0])
        #expect(model.rows.map(\.isActive) == [false, true, false])
        #expect(model.rows[1].accessibilityValue == "active")
        #expect(model.rows[0].accessibilityValue == "inactive")
        #expect(model.rows[2].accessibilityValue == "inactive")
        #expect(model.rows.map(\.isVisible) == [true, false, true])
        #expect(model.activeIndex == 1)
    }

    @Test func emptyModel() {
        #expect(LayerListModel.empty.rows.isEmpty)
        #expect(LayerListModel.empty.activeIndex == nil)
        for command in LayerPanelCommand.allCases {
            #expect(!LayerListModel.empty.isEnabled(command), "\(command.rawValue)")
        }
        #expect(LayerListModel.empty.moveTarget(displaySource: [0], displayDestination: 0) == nil)
        #expect(LayerListModel.empty.displayPosition(ofLayerIndex: 0) == nil)
        #expect(LayerListModel.empty.layerIndex(atDisplayPosition: 0) == nil)
    }

    @Test func enablementMatchesMenuValidation() {
        // Hand-written expected enablement (spec item 5's table): `i` = active index,
        // `n` = layer count. Add/Duplicate/Properties: always; Delete: n > 1; Merge
        // Down / Move Down: i > 0; Move Up: i < n − 1.
        struct Expectation {
            let names: [String]
            let active: Int
            let add, delete, duplicate, merge, up, down: Bool
        }
        let table: [Expectation] = [
            .init(names: ["A"], active: 0, add: true, delete: false, duplicate: true,
                  merge: false, up: false, down: false),
            .init(names: ["A", "B"], active: 0, add: true, delete: true, duplicate: true,
                  merge: false, up: true, down: false),
            .init(names: ["A", "B"], active: 1, add: true, delete: true, duplicate: true,
                  merge: true, up: false, down: true),
            .init(names: ["A", "B", "C"], active: 0, add: true, delete: true, duplicate: true,
                  merge: false, up: true, down: false),
            .init(names: ["A", "B", "C"], active: 1, add: true, delete: true, duplicate: true,
                  merge: true, up: true, down: true),
            .init(names: ["A", "B", "C"], active: 2, add: true, delete: true, duplicate: true,
                  merge: true, up: false, down: true),
        ]
        for row in table {
            let layered = image(names: row.names, active: row.active)
            let state = DocumentState(image: layered)
            let model = LayerListModel(image: layered)
            let expected: [(LayerPanelCommand, LayerCommand?, Bool)] = [
                (.addNewLayer, .addNewLayer, row.add),
                (.deleteLayer, .deleteLayer, row.delete),
                (.duplicateLayer, .duplicateLayer, row.duplicate),
                (.mergeLayerDown, .mergeLayerDown, row.merge),
                (.moveLayerUp, .moveLayerUp, row.up),
                (.moveLayerDown, .moveLayerDown, row.down),
                (.layerProperties, nil, true),
            ]
            for (panelCommand, menuCommand, enabled) in expected {
                #expect(model.isEnabled(panelCommand) == enabled,
                        "\(row.names) active \(row.active): \(panelCommand.rawValue)")
                if let menuCommand {
                    // L-1: the panel's enablement equals 0024's menu validation.
                    #expect(model.isEnabled(panelCommand) == menuCommand.isEnabled(in: state),
                            "\(panelCommand.rawValue)")
                }
            }
        }
    }

    @Test func moveTargetMapping() {
        // count 4; hand-computed (spec item 5): p = D > s ? D − 1 : D;
        // from = 3 − s, to = 3 − p.
        let model = LayerListModel(image: image(names: ["A", "B", "C", "D"], active: 0))
        func target(_ source: IndexSet, _ destination: Int) -> String {
            guard let target = model.moveTarget(displaySource: source,
                                                displayDestination: destination) else {
                return "nil"
            }
            return "(\(target.from), \(target.to))"
        }
        #expect(target([0], 2) == "(3, 2)")
        #expect(target([0], 4) == "(3, 0)")
        #expect(target([3], 0) == "(0, 3)")
        #expect(target([2], 1) == "(1, 2)")
        #expect(target([1], 1) == "nil")    // drop into its own gap: no-op
        #expect(target([1], 2) == "nil")    // drop after itself: no-op
        #expect(target([0, 1], 2) == "nil") // multi-selection: nothing
        #expect(target([5], 0) == "nil")    // source out of range
        #expect(target([0], 9) == "nil")    // destination out of range
        #expect(target([], 2) == "nil")     // no source
    }

    @Test func displayIndexConversion() {
        let model = LayerListModel(image: image(names: ["A", "B", "C"], active: 0))
        #expect(model.displayPosition(ofLayerIndex: 2) == 0)
        #expect(model.layerIndex(atDisplayPosition: 0) == 2)
        #expect(model.displayPosition(ofLayerIndex: 0) == 2)
        #expect(model.layerIndex(atDisplayPosition: 2) == 0)
        #expect(model.displayPosition(ofLayerIndex: 3) == nil)
        #expect(model.displayPosition(ofLayerIndex: -1) == nil)
        #expect(model.layerIndex(atDisplayPosition: 3) == nil)
        #expect(model.layerIndex(atDisplayPosition: -1) == nil)
    }

    @Test func visibilityToggleBuildsTheStep() {
        let layered = image(names: ["A", "B"], visible: [true, false], active: 0)
        let model = LayerListModel(image: layered)
        guard let item = model.visibilityToggle(forLayerIndex: 1, in: layered) else {
            Issue.record("expected a visibility item")
            return
        }
        #expect(item.name == "Show Layer")
        #expect(item.layerID == layered.layers[1].id)
        #expect(item.before.isVisible == false)
        #expect(item.after.isVisible == true)
        #expect(model.visibilityToggle(forLayerIndex: 2, in: layered) == nil)
    }

    @Test func inconsistentImageDoesNotCrash() throws {
        // Defensive path (spec item 5): a hand-corrupted active index clamps into range;
        // the panel must not crash on the impossible image.
        var layered = image(names: ["A", "B", "C"], active: 0)
        layered.activeLayerIndex = 9
        var model = LayerListModel(image: layered)
        #expect(model.activeIndex == 2)
        #expect(model.rows.filter(\.isActive).count == 1)
        #expect(model.rows.first?.isActive == true)
        layered.activeLayerIndex = -4
        model = LayerListModel(image: layered)
        #expect(model.activeIndex == 0)
        #expect(model.rows.last?.isActive == true)
    }
}
