//
//  FanSpeedSlider.swift
//  Sensors
//

import Cocoa
import Kit

/// A continuous native slider without notches, or a magnetic RPM selector with
/// configured notches. Programmatic values (including Min/Max) remain exact.
internal final class FanSpeedSlider: NSSlider {
    internal static let controlHeight: CGFloat = 44
    private let configProvider: () -> FanSliderConfig?
    private var isDragging = false

    internal var notches: [Int] { (self.cell as? FanSpeedSliderCell)?.notches ?? [] }
    internal var cursorTravelRect: NSRect {
        (self.cell as? FanSpeedSliderCell)?.cursorTravelRect(flipped: self.isFlipped) ?? .zero
    }

    internal init(frame: NSRect = .zero, configProvider: @escaping () -> FanSliderConfig? = {
        FanSliderController.shared.currentConfig()
    }) {
        self.configProvider = configProvider
        super.init(frame: frame)
        self.cell = FanSpeedSliderCell()
        self.cell?.controlView = self
        self.isContinuous = true
        self.trackFillColor = .systemBlue
        self.setAccessibilityLabel(localizedString("Manual slider"))
        NotificationCenter.default.addObserver(self, selector: #selector(self.reloadConfiguration),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: Self.controlHeight)
    }

    override func viewWillDraw() {
        if !self.isDragging { self.reloadConfiguration() }
        super.viewWillDraw()
    }

    @objc internal func reloadConfiguration() {
        guard !self.isDragging, let cell = self.cell as? FanSpeedSliderCell else { return }
        let notches = self.configProvider()?.activeNotches(minimum: Int(self.minValue), maximum: Int(self.maxValue)) ?? []
        guard cell.notches != notches else { return }
        cell.notches = notches
        let description = notches.isEmpty ? nil : notches.map(String.init).joined(separator: ", ") + " RPM"
        self.toolTip = description
        self.setAccessibilityHelp(description)
        self.needsDisplay = true
    }

    private func nearestNotch(to value: Double) -> Double {
        Double(self.notches.min(by: { lhs, rhs in
            let left = abs(Double(lhs) - value)
            let right = abs(Double(rhs) - value)
            return left == right ? lhs > rhs : left < right
        }) ?? Int(value.rounded()))
    }

    private func selectSpeed(_ value: Double) {
        guard self.doubleValue != value else { return }
        self.doubleValue = value
        self.needsDisplay = true
        _ = self.sendAction(self.action, to: self.target)
    }

    override func mouseDown(with event: NSEvent) {
        self.reloadConfiguration()
        guard self.isEnabled, !self.notches.isEmpty, let window = self.window,
              let cell = self.cell as? FanSpeedSliderCell else {
            super.mouseDown(with: event)
            return
        }

        window.makeFirstResponder(self)
        self.isDragging = true
        cell.isHighlighted = true
        self.needsDisplay = true
        defer {
            self.isDragging = false
            cell.isHighlighted = false
            self.needsDisplay = true
        }

        // Use the absolute cursor position, never the snapped thumb's position
        // or a drag offset: snapping must not prevent reaching the next notch.
        var current = event
        while true {
            let point = self.convert(current.locationInWindow, from: nil)
            let track = self.cursorTravelRect
            let fraction = min(1, max(0, (point.x - track.minX) / track.width))
            self.selectSpeed(self.nearestNotch(to: self.minValue + Double(fraction) * (self.maxValue - self.minValue)))
            window.displayIfNeeded()
            if current.type == .leftMouseUp { break }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                              inMode: .eventTracking, dequeue: true) else { break }
            current = next
        }
    }

    private func stepNotch(forward: Bool) {
        let next = forward
            ? self.notches.first(where: { Double($0) > self.doubleValue }) ?? self.notches.last!
            : self.notches.last(where: { Double($0) < self.doubleValue }) ?? self.notches.first!
        self.selectSpeed(Double(next))
    }

    override func keyDown(with event: NSEvent) {
        self.reloadConfiguration()
        guard self.isEnabled, !self.notches.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 125: self.stepNotch(forward: false)
        case 124, 126: self.stepNotch(forward: true)
        case 115: self.selectSpeed(Double(self.notches.first!))
        case 119: self.selectSpeed(Double(self.notches.last!))
        default: super.keyDown(with: event)
        }
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        // Native accessibility value changes must use the same notch selection.
        if !self.isDragging { self.reloadConfiguration() }
        if !self.notches.isEmpty { self.doubleValue = self.nearestNotch(to: self.doubleValue) }
        return super.sendAction(action, to: target)
    }

    override func accessibilityPerformIncrement() -> Bool {
        self.reloadConfiguration()
        guard self.isEnabled else { return false }
        guard !self.notches.isEmpty else { return super.accessibilityPerformIncrement() }
        self.stepNotch(forward: true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        self.reloadConfiguration()
        guard self.isEnabled else { return false }
        guard !self.notches.isEmpty else { return super.accessibilityPerformDecrement() }
        self.stepNotch(forward: false)
        return true
    }

    override func accessibilityValueDescription() -> String? {
        "\(Int(self.doubleValue.rounded())) RPM"
    }
}

private final class FanSpeedSliderCell: NSSliderCell {
    var notches: [Int] = []

    func cursorTravelRect(flipped: Bool) -> NSRect {
        var track = self.barRect(flipped: flipped).insetBy(dx: self.knobRect(flipped: flipped).width / 2, dy: 0)
        track.size.width = max(1, track.width)
        return track
    }

    private func position(for value: Double, in track: NSRect) -> CGFloat {
        let fraction = self.maxValue > self.minValue ? (value - self.minValue) / (self.maxValue - self.minValue) : 0
        return track.minX + CGFloat(min(1, max(0, fraction))) * track.width
    }

    private func notchColor(for value: Int) -> NSColor {
        guard self.isEnabled else { return .disabledControlTextColor }
        return Double(value) <= self.doubleValue ? .systemBlue : .secondaryLabelColor
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        super.drawBar(inside: rect, flipped: flipped)
        guard !self.notches.isEmpty else { return }
        let track = self.cursorTravelRect(flipped: flipped)
        for value in self.notches {
            let passed = self.isEnabled && Double(value) <= self.doubleValue
            let color = self.notchColor(for: value)
            // A lighter blue distinguishes passed ticks from the blue track
            // without changing their size, shape, or position.
            let markColor = passed ? color.blended(withFraction: 0.55, of: .white) ?? color : color
            markColor.setFill()
            let tick = NSRect(x: self.position(for: Double(value), in: track) - 1, y: track.midY - 4, width: 2, height: 8)
            NSBezierPath(roundedRect: tick, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard !self.notches.isEmpty else { super.draw(withFrame: cellFrame, in: controlView); return }
        // AppKit draws the original track, thumb, and focus ring; only the notch
        // marks and RPM labels are added to the native appearance.
        super.draw(withFrame: cellFrame, in: controlView)
        let track = self.cursorTravelRect(flipped: controlView.isFlipped)

        let selected = self.notches.first(where: { Double($0) == self.doubleValue })
        let labels = self.notches.map { value -> (Int, NSString, NSRect) in
            let text = NSString(string: "\(value)")
            let size = text.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)])
            let x = min(controlView.bounds.maxX - size.width, max(controlView.bounds.minX,
                        self.position(for: Double(value), in: track) - size.width / 2))
            let y = controlView.isFlipped ? track.midY + 11 : track.midY - 11 - size.height
            return (value, text, NSRect(x: x, y: y, width: size.width, height: size.height))
        }
        let selectedLabel = labels.first(where: { $0.0 == selected })?.2
        var lastLabelEdge = -CGFloat.infinity
        for (value, text, label) in labels {
            let active = value == selected
            // Keep every tick, but avoid overlapping labels in dense configs.
            // The selected RPM always gets its label and is also read out below.
            if !active {
                if let selectedLabel, label.insetBy(dx: -3, dy: 0).intersects(selectedLabel) { continue }
                if label.minX < lastLabelEdge + 4 { continue }
            }
            text.draw(in: label, withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: self.notchColor(for: value)
            ])
            lastLabelEdge = label.maxX
        }
    }
}
