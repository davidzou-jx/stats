// Standalone UI regressions. Creates an unshown test window, injects mouse/key
// events, and never launches Stats or sends commands to FanController.
import Cocoa
import Kit
@testable import Sensors

private final class SliderTarget: NSObject {
    var values: [Int] = []
    @objc func changed(_ sender: NSSlider) { self.values.append(sender.integerValue) }
}

private final class PreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        self.bounds.fill()
    }
}

@main
struct FanSliderTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        self.testFanControlConstruction()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("fan-slider.json")
        let controller = FanSliderController(configURL: configURL)
        var config = FanSliderConfig(enabled: true, notches: [6000, 3000, 3500, 5000, 5000, 8000, 1000])
        try config.encoded()!.write(to: configURL)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let slider = FanSpeedSlider(frame: NSRect(x: 20, y: 30, width: 320, height: FanSpeedSlider.controlHeight),
                                    configProvider: { controller.currentConfig() })
        slider.minValue = 2500
        slider.maxValue = 7500
        slider.doubleValue = 3000
        let target = SliderTarget()
        slider.target = target
        slider.action = #selector(SliderTarget.changed(_:))
        window.contentView!.addSubview(slider)
        slider.reloadConfiguration()
        precondition(slider.notches == [3000, 3500, 5000, 6000], "rendering and dragging must share the in-range, unique RPMs")
        _ = self.snapshot(slider)
        let cell = slider.cell as! NSSliderCell
        let track = slider.cursorTravelRect
        let minimumX = cell.knobRect(flipped: slider.isFlipped).midX
        slider.doubleValue = 6000
        _ = self.snapshot(slider)
        precondition(abs(cell.knobRect(flipped: slider.isFlipped).midX - minimumX - track.width * 0.6) < 0.01,
                     "uneven notches must use RPM positions, not evenly spaced indices")

        let native = NSSlider(frame: slider.bounds)
        native.minValue = slider.minValue
        native.maxValue = slider.maxValue
        native.doubleValue = slider.doubleValue
        _ = self.snapshot(native)
        let actualKnob = cell.knobRect(flipped: slider.isFlipped)
        let nativeKnob = (native.cell as! NSSliderCell).knobRect(flipped: native.isFlipped)
        precondition(actualKnob == nativeKnob, "notches must retain the native thumb's size and position (\(actualKnob), \(nativeKnob))")
        slider.doubleValue = 4500
        let tinted = self.snapshot(slider)
        func notchColor(at rpm: Double) -> NSColor {
            let track = slider.cursorTravelRect
            let x = track.minX + CGFloat((rpm - slider.minValue) / (slider.maxValue - slider.minValue)) * track.width
            let y = slider.isFlipped ? track.midY : slider.bounds.height - track.midY
            let pixelX = Int(x * CGFloat(tinted.pixelsWide) / slider.bounds.width)
            let pixelY = Int(y * CGFloat(tinted.pixelsHigh) / slider.bounds.height)
            return tinted.colorAt(x: pixelX, y: pixelY)!.usingColorSpace(.deviceRGB)!
        }
        for rpm in [3000.0, 3500.0] {
            let color = notchColor(at: rpm)
            precondition(color.blueComponent > color.redComponent + 0.2 && color.blueComponent > color.greenComponent + 0.1,
                         "every passed notch must be blue, including notches below the selected speed")
        }
        for rpm in [5000.0, 6000.0] {
            let color = notchColor(at: rpm)
            precondition(abs(color.blueComponent - color.redComponent) < 0.05, "future notches must remain neutral")
        }
        slider.doubleValue = 3000

        func mouse(_ type: NSEvent.EventType, rpm: Double) -> NSEvent {
            let track = slider.cursorTravelRect
            let x = track.minX + CGFloat((rpm - slider.minValue) / (slider.maxValue - slider.minValue)) * track.width
            let point = slider.convert(NSPoint(x: x, y: track.midY), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(from start: Double, through speeds: [Double], to end: Double) {
            for speed in speeds { app.postEvent(mouse(.leftMouseDragged, rpm: speed), atStart: false) }
            app.postEvent(mouse(.leftMouseUp, rpm: end), atStart: false)
            slider.mouseDown(with: mouse(.leftMouseDown, rpm: start))
        }
        drag(from: 3300, through: [3200, 3250, 4300, 4600, 5400, 5500], to: 6100)
        precondition(target.values == [3500, 3000, 3500, 5000, 6000],
                     "the thumb must snap during dragging, stay on the nearest notch, and prefer higher RPM on ties")
        precondition(slider.integerValue == 6000)
        target.values.removeAll()
        drag(from: 6000, through: [5400, 4200, 3240, 2000, 8000], to: 6000)
        precondition(target.values == [5000, 3500, 3000, 6000], "reverse drags and points outside the track must not trap the thumb")

        func key(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: code)!
            slider.keyDown(with: event)
        }
        key(123)
        precondition(slider.integerValue == 5000)
        key(124)
        precondition(slider.integerValue == 6000)
        key(115)
        precondition(slider.integerValue == 3000)
        key(119)
        precondition(slider.integerValue == 6000)
        precondition(slider.accessibilityPerformDecrement() && slider.integerValue == 5000)
        precondition(slider.accessibilityPerformIncrement() && slider.integerValue == 6000)
        precondition(slider.accessibilityValueDescription() == "6000 RPM")
        slider.doubleValue = slider.minValue
        precondition(slider.doubleValue == 2500, "explicit Min and Max must remain reachable even when absent from the notches")
        slider.doubleValue = slider.maxValue
        precondition(slider.doubleValue == 7500)
        slider.isEnabled = false
        precondition(!slider.accessibilityPerformIncrement() && slider.doubleValue == 7500)
        slider.isEnabled = true

        // Refresh configuration without recreating the popup or moving its value.
        config.notches = [4000]
        try config.encoded()!.write(to: configURL)
        slider.reloadConfiguration()
        precondition(slider.notches == [4000] && slider.integerValue == 7500)
        drag(from: 6000, through: [3000], to: 7000)
        precondition(slider.integerValue == 4000, "a single notch must work at its RPM position")
        for fallback in [FanSliderConfig(enabled: false, notches: [4000]), FanSliderConfig(enabled: true, notches: [1000, 8000])] {
            try fallback.encoded()!.write(to: configURL)
            slider.reloadConfiguration()
            precondition(slider.notches.isEmpty && slider.toolTip == nil)
            slider.doubleValue = 4321
            _ = slider.sendAction(slider.action, to: slider.target)
            precondition(slider.integerValue == 4321, "disabled or out-of-range notches must preserve continuous control")
        }
        try Data("{broken".utf8).write(to: configURL)
        slider.reloadConfiguration()
        precondition(slider.notches.isEmpty, "an invalid config must safely restore the native slider")

        if CommandLine.arguments.count > 1 { try self.renderPreviews(at: CommandLine.arguments[1]) }
        print("Fan-slider UI regressions passed (native appearance/tinting, layout, magnetic dragging, keyboard/accessibility, Min/Max and config refresh/fallback).")
    }

    private static func snapshot(_ view: NSView) -> NSBitmapImageRep {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func testFanControlConstruction() {
        // This standalone process has no app preference domain. Force the
        // controller's availability so the real manual container is constructed
        // and laid out without contacting FanController or scheduling writes.
        precondition(Bundle.main.bundleIdentifier == nil)
        precondition(!Store.shared.bool(key: "Sensors_speed", defaultValue: false))
        let fans = [Fan(id: 0, key: "F0Ac", name: "Test fan", minSpeed: 2500, maxSpeed: 7500, value: 3500, mode: .forced)]
        for width in [CGFloat(280), CGFloat(360)] {
            let control = FanControlView(fans: fans, width: width, controllerAvailable: true, callback: {})
            guard let manual = control.arrangedSubviews.first(where: { $0.identifier?.rawValue == "control" }) as? NSStackView,
                  let slider = manual.arrangedSubviews.compactMap({ $0 as? FanSpeedSlider }).first else {
                preconditionFailure("the fan control must contain the manual slider")
            }
            control.layoutSubtreeIfNeeded()
            precondition(slider.superview === manual)
            precondition(abs(slider.frame.width - (width - Constants.Popup.margins)) < 0.01,
                         "the slider must fill the manual container's inset width")
            precondition(abs(slider.frame.height - FanSpeedSlider.controlHeight) < 0.01)
            precondition(slider.minValue == 2500 && slider.maxValue == 7500,
                         "the fan control must retain its hardware range by default")
        }
    }

    private static func renderPreviews(at path: String) throws {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = PreviewBackground(frame: NSRect(x: 0, y: 0, width: 380, height: 420))
            view.appearance = NSAppearance(named: appearance)
            let examples: [(String, FanSliderConfig, Double)] = [
                ("Configured notches", FanSliderConfig(enabled: true, notches: [2500, 3500, 4500, 5500, 6500, 7500]), 4500),
                ("Uneven notch spacing", FanSliderConfig(enabled: true, notches: [3000, 3500, 5000, 6000]), 3500),
                ("Dense labels", FanSliderConfig(enabled: true, notches: [3000, 3050, 3100, 3150, 3200, 4500, 6500]), 3100),
                ("Single notch", FanSliderConfig(enabled: true, notches: [6000]), 6000),
                ("Snapping disabled", FanSliderConfig(enabled: false, notches: [3000, 5000]), 4200),
            ]
            for (index, example) in examples.enumerated() {
                let y = 420 - CGFloat(index + 1) * 80
                let title = NSTextField(labelWithString: example.0)
                title.frame = NSRect(x: 20, y: y + 48, width: 340, height: 20)
                title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                view.addSubview(title)
                let slider = FanSpeedSlider(frame: NSRect(x: 20, y: y, width: 340, height: FanSpeedSlider.controlHeight),
                                            configProvider: { example.1 })
                slider.minValue = 2500
                slider.maxValue = 7500
                slider.doubleValue = example.2
                slider.reloadConfiguration()
                view.addSubview(slider)
            }
            let bitmap = self.snapshot(view)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("fan-slider-\(name).png"))
        }
    }
}
