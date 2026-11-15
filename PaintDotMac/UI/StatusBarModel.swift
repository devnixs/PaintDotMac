import Foundation
import Observation

/// The document window's status bar state (spec 0004, APP-5), one per window;
/// `StatusBarView` renders it. The unit is app-wide through `AppSettings` — changing it in
/// one window updates every open window via `.appSettingsDidChange`.
@MainActor
@Observable final class StatusBarModel {
    /// The image pixel under the cursor, `nil` when the pointer left the canvas.
    var cursorPixel: PixelPoint?
    /// Always `nil` in 0004; 0014 fills it (APP-5 keeps the field present but empty).
    var selectionSize: PixelSize?
    var imageSize: PixelSize
    /// The document's DPI (`LayeredImage.dpi`); 0 in/cm derive from it (D-7).
    var dpi: Double
    var zoom: Double
    var unit: MeasurementUnit

    private let settings: AppSettings
    private var settingsObserver: NotificationObserverBox?

    init(imageSize: PixelSize, dpi: Double, zoom: Double = 1,
         unit: MeasurementUnit? = nil,
         settings: AppSettings = AppSettings(),
         notificationCenter: NotificationCenter = .default) {
        self.imageSize = imageSize
        self.dpi = dpi
        self.zoom = zoom
        self.settings = settings
        self.unit = unit ?? settings.measurementUnit
        // Assigned after `self` is fully initialized (the handler references `self` weakly);
        // the box removes itself on deinit (Swift 6 deinit isolation).
        settingsObserver = NotificationObserverBox(
            center: notificationCenter, name: .appSettingsDidChange, object: nil
        ) { [weak self] in
            // Re-read on the main actor (AppSettings may post from any thread).
            Task { @MainActor [weak self] in self?.refreshUnit() }
        }
    }

    /// 0006/0007 may replace the whole image (size or DPI); the fields follow.
    func update(image: LayeredImage) {
        imageSize = image.size
        dpi = image.dpi
    }

    /// Writes the shared setting, which notifies every window (and 0046's Settings window).
    /// The local field updates immediately; the notification keeps the other windows in step.
    func selectUnit(_ unit: MeasurementUnit) {
        self.unit = unit
        settings.measurementUnit = unit
    }

    /// Floors a canvas point to the image pixel under it; outside the image the values are
    /// simply negative or ≥ the size, as in Paint.NET. `nil` clears the field.
    func setCursor(canvasPoint: CGPoint?) {
        guard let canvasPoint else { cursorPixel = nil; return }
        cursorPixel = PixelPoint(x: Int(floorClamped: canvasPoint.x),
                                 y: Int(floorClamped: canvasPoint.y))
    }

    private func refreshUnit() {
        unit = settings.measurementUnit
    }

    // MARK: - Shown strings

    var cursorText: String {
        cursorPixel.map { unit.formatPoint($0, dpi: dpi) } ?? ""
    }

    var selectionSizeText: String {
        selectionSize.map { unit.formatSize($0, dpi: dpi) } ?? ""
    }

    var imageSizeText: String { unit.formatSize(imageSize, dpi: dpi) }

    var zoomText: String { ZoomLevels.percentString(zoom) }
}

private extension Int {
    /// Total `floor → Int` for cursor coordinates: a wild canvas coordinate (possible only
    /// through degenerate geometry) shows a clamped number, never traps.
    init(floorClamped value: Double) {
        let floored = value.isFinite ? value.rounded(.down) : 0
        guard floored >= -9.0e18, floored <= 9.0e18 else {
            self = floored < 0 ? Int.min : Int.max
            return
        }
        self.init(floored)
    }
}
