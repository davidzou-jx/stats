//
//  popup.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 22/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private var list: [String: NSView] = [:]
    private var fansControlView: FanControlView? = nil
    
    private static let temperatureOrder: [String: Int] = [
        "Ts0P": 0,                  // Palm Rest
        "Average Airflow": 1,       // Average Air Flow
        "Average CPU": 2,
        "Hottest CPU": 3,
        "Average Super Cores": 4,
        "Average Performance Cores": 5,
        "Average GPU": 6,
        "Hottest GPU": 7,
        "TW0P": 8,                  // Airport
        "Average Battery": 9,
        "TH0x": 10                  // NAND
    ]
    private static let indentedTemperatureKeys: Set<String> = [
        "Hottest CPU", "Average Super Cores", "Average Performance Cores", "Hottest GPU"
    ]
    private static let powerOrder: [String: Int] = [
        "PSTR": 0,                  // System Total
        "Average System Total": 1,  // indented
        "PPBR": 2,                  // Battery
        "PDTR": 3,                  // DC In
        "CPU Power": 4,
        "GPU Power": 5,
        "ANE Power": 6,
        "RAM Power": 7,
        "PCI Power": 8
    ]
    private static let indentedPowerKeys: Set<String> = [
        "Average System Total"
    ]
    
    private var unknownSensorsState: Bool { Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
    private var fanValueState: FanValue = .percentage
    
    private var sensors: [Sensor_p] = []
    private let settingsView: NSStackView = NSStackView()
    private let sensorsCache = PopupCache<[Sensor_p]>()
    
    private var fanControlState: Bool {
        get { Store.shared.bool(key: "Sensors_fanControl", defaultValue: true) }
        set { Store.shared.set(key: "Sensors_fanControl", value: newValue) }
    }
    
    public init() {
        super.init(ModuleType.sensors, frame: NSRect( x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.fanValueState = FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: self.fanValueState.rawValue)) ?? .percentage
        
        self.orientation = .vertical
        self.spacing = 0
        self.translatesAutoresizingMaskIntoConstraints = false
        
        self.settingsView.orientation = .vertical
        self.settingsView.spacing = Constants.Settings.margin
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Fan value"), component: selectView(
                action: #selector(self.toggleFanValue),
                items: FanValues,
                selected: self.fanValueState.rawValue
            ))
        ]))
        #if arch(arm64)
        NotificationCenter.default.addObserver(self, selector: #selector(self.checkFanModesAndResetFtst), name: .checkFanModes, object: nil)
        #endif
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    #if arch(arm64)
    @objc private func checkFanModesAndResetFtst() {
        guard let view = self.fansControlView, view.mode.isAutomatic else { return }
        FanController.shared.resetFanControl()
    }
    #endif
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func setup(_ values: [Sensor_p]? = nil, reload: Bool = false) {
        guard let values = reload ? self.sensors : values else { return }
        let fans = values.filter({ $0.type == .fan && $0.popupState })
        var sensors = values
        if !self.unknownSensorsState {
            sensors = sensors.filter({ $0.group != .unknown })
        }
        
        self.subviews.forEach({ $0.removeFromSuperview() })
        if !reload {
            self.settingsView.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("sensor") }).forEach { v in
                v.removeFromSuperview()
            }
        }
        
        if !fans.isEmpty {
            let separator = SeparatorView(
                label: localizedString("Fans"),
                button: PopupButton(toolTip: localizedString("Control"), state: self.fanControlState) { [weak self] in
                    self?.toggleFanControl()
                }
            )
            separator.widthAnchor.constraint(equalToConstant: Constants.Popup.width).isActive = true
            self.addArrangedSubview(separator)
            
            let container = NSStackView()
            container.orientation = .vertical
            container.spacing = Constants.Popup.spacing
            
            var controlFans: [Fan] = []
            fans.forEach { (f: Sensor_p) in
                if let fan = f as? Fan {
                    if f.isComputed {
                        let sensor = SensorView(fan, width: self.frame.width, toggleable: false) {}
                        self.list[fan.key] = sensor
                        container.addArrangedSubview(sensor)
                    } else {
                        controlFans.append(fan)
                    }
                }
            }
            if !controlFans.isEmpty {
                let view = FanControlView(fans: controlFans, width: self.frame.width) { [weak self] in
                    let h = container.arrangedSubviews.map({ $0.bounds.height + container.spacing }).reduce(0, +) - container.spacing
                    if container.frame.size.height != h && h >= 0 {
                        container.setFrameSize(NSSize(width: container.frame.width, height: h))
                    }
                    self?.recalculateHeight()
                }
                self.fansControlView = view
                controlFans.forEach { self.list[$0.key] = view }
                container.addArrangedSubview(view)
            }
            
            let h = container.arrangedSubviews.map({ $0.bounds.height + container.spacing }).reduce(0, +) - container.spacing
            if container.frame.size.height != h {
                container.setFrameSize(NSSize(width: container.frame.width, height: h))
            }
            self.addArrangedSubview(container)
        }
        
        var types: [SensorType] = []
        sensors.forEach { (s: Sensor_p) in
            if !types.contains(s.type) {
                types.append(s.type)
            }
        }
        
        types.forEach { (typ: SensorType) in
            var filtered = sensors.filter{ $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { (s: Sensor_p) in
                if !groups.contains(s.group) {
                    groups.append(s.group)
                }
            }
            
            if !reload {
                let section = PreferencesSection(title: localizedString(typ.rawValue))
                section.identifier = NSUserInterfaceItemIdentifier("sensor")
                groups.forEach { (group: SensorGroup) in
                    filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                        let btn = switchView(
                            action: #selector(self.toggleSensor),
                            state: s.popupState
                        )
                        btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                        section.add(PreferencesRow(localizedString(s.name), component: btn))
                    }
                }
                self.settingsView.addArrangedSubview(section)
            }
            
            if typ == .fan { return }
            filtered = filtered.filter{ $0.popupState }
            if filtered.isEmpty { return }
            
            self.addArrangedSubview(separatorView(localizedString(typ.rawValue), width: self.frame.width))
            let order: [String: Int]
            let indentedKeys: Set<String>
            switch typ {
            case .temperature:
                order = Self.temperatureOrder
                indentedKeys = Self.indentedTemperatureKeys
            case .power:
                order = Self.powerOrder
                indentedKeys = Self.indentedPowerKeys
            default:
                order = [:]
                indentedKeys = []
            }
            if !order.isEmpty {
                let ordered = filtered.sorted { a, b in
                    let aRank = order[a.key] ?? Int.max
                    let bRank = order[b.key] ?? Int.max
                    if aRank != bRank { return aRank < bRank }
                    return false
                }
                ordered.forEach { (s: Sensor_p) in
                    let indent = indentedKeys.contains(s.key) ? 3 : 0
                    let sensor = SensorView(s, width: self.frame.width, indent: indent) { [weak self] in
                        self?.recalculateHeight()
                    }
                    self.addArrangedSubview(sensor)
                    self.list[s.key] = sensor
                }
            } else {
                groups.forEach { (group: SensorGroup) in
                    filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                        let sensor = SensorView(s, width: self.frame.width) { [weak self] in
                            self?.recalculateHeight()
                        }
                        self.addArrangedSubview(sensor)
                        self.list[s.key] = sensor
                    }
                }
            }
        }
        
        if !reload {
            self.sensors = values
        }
        self.recalculateHeight()
    }
    
    internal func usageCallback(_ values: [Sensor_p]) {
        DispatchQueue.main.async(execute: {
            values.filter({ $0 is Sensor }).forEach { (s: Sensor_p) in
                if let sensor = self.list[s.key] as? SensorView {
                    sensor.addHistoryPoint(s)
                }
            }
            
            self.sensorsCache.apply(values, visible: self.window?.isVisible ?? false, render: self.renderSensors)
        })
    }
    
    private func renderSensors(_ values: [Sensor_p]) {
        values.forEach { (s: Sensor_p) in
            switch self.list[s.key] {
            case let fan as FanControlView:
                if let f = s as? Fan {
                    fan.update(f)
                }
            case let sensor as SensorView:
                sensor.update(s)
            case .none, .some:
                break
            }
        }
    }
    
    public override func appear() {
        self.replay(self.sensorsCache, render: self.renderSensors)
    }
    
    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        self.settingsView
    }
    
    @objc private func toggleFanValue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let value = FanValue(rawValue: key) {
            self.fanValueState = value
            Store.shared.set(key: "Sensors_popup_fanValue", value: self.fanValueState.rawValue)
        }
    }
    
    // MARK: helpers
    
    @objc private func toggleSensor(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)_popup", value: controlState(sender))
        self.setup(reload: true)
    }
    
    @objc private func toggleFanControl() {
        self.fanControlState = !self.fanControlState
        NotificationCenter.default.post(name: .toggleFanControl, object: nil, userInfo: ["state": self.fanControlState])
    }
}

// MARK: - Sensor view

internal class SensorView: NSStackView {
    public var sizeCallback: (() -> Void)
    
    private var valueView: ValueSensorView!
    private var chartView: ChartSensorView!
    
    private var openned: Bool = false
    
    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, indent: Int = 0, callback: @escaping (() -> Void)) {
        self.sizeCallback = callback
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.orientation = .vertical
        self.distribution = .fillProportionally
        self.spacing = 0
        
        self.valueView = ValueSensorView(sensor, width: width, toggleable: toggleable, indent: indent, callback: { [weak self] in
            self?.open()
        })
        self.chartView = ChartSensorView(width: width, suffix: sensor.unit)
        
        self.addArrangedSubview(self.valueView)
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: self.bounds.width)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ sensor: Sensor_p) {
        var value = sensor.formattedPopupValue
        if let fan = sensor as? Fan {
            value = self.fanValueState == .percentage ? "\(fan.percentage)%" : fan.formattedValue
        }
        self.valueView.update(value)
    }
    
    public func addHistoryPoint(_ sensor: Sensor_p) {
        self.chartView.update(sensor.localValue, sensor.unit)
    }
    
    private func open() {
        if self.openned {
            self.chartView.removeFromSuperview()
        } else {
            self.addArrangedSubview(self.chartView)
        }
        self.openned = !self.openned
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback()
    }
}

internal class ValueSensorView: NSStackView {
    public var callback: (() -> Void)
    
    private var labelView: LabelField = {
        let view = LabelField(frame: NSRect.zero)
        view.cell?.truncatesLastVisibleLine = true
        return view
    }()
    private var valueView: ValueField = ValueField(frame: NSRect.zero)
    
    private let isToggleable: Bool
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, indent: Int = 0, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.isToggleable = toggleable
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.wantsLayer = true
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.labelView.stringValue = indent > 0 ? String(repeating: " ", count: indent) + sensor.name : sensor.name
        self.labelView.toolTip = sensor.key
        self.valueView.stringValue = sensor.formattedValue
        
        self.addArrangedSubview(self.labelView)
        self.addArrangedSubview(self.valueView)
        
        if self.isToggleable {
            self.addTrackingArea(NSTrackingArea(
                rect: NSRect(x: 0, y: 0, width: self.frame.width, height: 22),
                options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }
        
        NSLayoutConstraint.activate([
            self.labelView.heightAnchor.constraint(equalToConstant: 16),
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ value: String) {
        self.valueView.stringValue = value
    }
    
    override func mouseDown(with theEvent: NSEvent) {
        guard self.isToggleable else { return }
        self.callback()
    }
    
    public override func mouseEntered(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.05)
    }
    
    public override func mouseExited(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .none
    }
}

internal class ChartSensorView: NSStackView {
    private var chart: LineChartView? = nil
    private var currentSuffix: String
    
    public init(width: CGFloat, suffix: String) {
        self.currentSuffix = suffix
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.chart = LineChartView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height), num: 120, scale: .linear)
        self.chart?.setSuffix(suffix)
        
        if let view = self.chart {
            self.addArrangedSubview(view)
        }
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.chart?.display()
    }
    
    public func update(_ value: Double, _ suffix: String) {
        guard let chart = self.chart else { return }
        if self.currentSuffix != suffix {
            self.currentSuffix = suffix
            chart.setSuffix(suffix)
        }
        chart.addValue(value/100)
    }
}

// MARK: - Fan view

internal class FanView: NSStackView {
    public var sizeCallback: (() -> Void)
    
    internal var fan: Fan
    private var ready: Bool = false
    
    private var controllerSetupView: NSView? = nil
    private var controlView: NSView? = nil
    private var buttonsView: NSView? = nil
    
    private var valueField: NSTextField? = nil
    private var sliderValueField: NSTextField? = nil
    
    private var slider: NSSlider? = nil
    private var modeButtons: ModeButtons? = nil
    private var debouncer: DispatchWorkItem? = nil
    
    private var barView: BarChartView = BarChartView(size: 6, horizontal: true)
    
    private var minBtn: NSButton? = nil
    private var maxBtn: NSButton? = nil
    
    private var speedState: Bool { Store.shared.bool(key: "Sensors_speed", defaultValue: false) }
    private var syncState: Bool { Store.shared.bool(key: "Sensors_fansSync", defaultValue: false) }
    private var speed: Double {
        get {
            if let v = self.fan.customSpeed, self.speedState {
                return Double(v)
            }
            return self.fan.value
        }
    }
    private var resetModeAfterSleep: Bool = false
    private var controlState: Bool
    private var controllerAvailable: Bool = false
    private var controllerButton: NSButton? = nil
    private var controllerPollTimer: Timer? = nil
    private var fanValue: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }
    
    private var horizontalMargin: CGFloat {
        self.edgeInsets.top + self.edgeInsets.bottom + (self.spacing*CGFloat(self.arrangedSubviews.count))
    }
    
    private var willSleepMode: FanMode? = nil // fan mode before sleep
    private var willSleepSpeed: Int? = nil // fan speed before sleep
    
    public init(_ fan: Fan, width: CGFloat, callback: @escaping (() -> Void)) {
        self.fan = fan
        self.sizeCallback = callback
        self.controlState = Store.shared.bool(key: "Sensors_fanControl", defaultValue: true)
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        
        self.controllerSetupView = self.controllerSetup()
        self.controlView = self.control()
        self.buttonsView = self.mode()
        
        self.orientation = .vertical
        self.alignment = .centerX
        self.distribution = .fillProportionally
        self.spacing = 1
        self.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        
        self.nameAndSpeed()
        self.setupControls()
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeListener), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepListener), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.syncFanSpeed), name: .syncFansControl, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.changeControllerState), name: .fanControllerState, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.controlCallback), name: .toggleFanControl, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.recheckControllerState), name: NSApplication.didBecomeActiveNotification, object: nil)
        
        if let fanMode = self.fan.customMode, self.speedState && fanMode != FanMode.automatic {
            FanController.shared.setFanMode(fan.id, mode: fanMode.rawValue)
            self.modeButtons?.setMode(FanMode(rawValue: fanMode.rawValue) ?? .automatic)
            
            self.setSpeed(value: Int(self.speed), then: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.sliderValueField?.textColor = .systemBlue
                }
            })
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.controllerPollTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: .syncFansControl, object: nil)
        NotificationCenter.default.removeObserver(self, name: .fanControllerState, object: nil)
        NotificationCenter.default.removeObserver(self, name: .toggleFanControl, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    private func nameAndSpeed() {
        let row: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 16))
        row.widthAnchor.constraint(equalToConstant: self.frame.width).isActive = true
        row.heightAnchor.constraint(equalToConstant: row.bounds.height).isActive = true
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 0
        
        let nameField: NSTextField = TextView()
        nameField.stringValue = self.fan.name
        nameField.toolTip = self.fan.key
        nameField.cell?.truncatesLastVisibleLine = true
        
        let value = self.fan.value
        let valueField: NSTextField = TextView()
        valueField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        valueField.alignment = .trailing
        valueField.stringValue = self.fanValue == .percentage ? "\(self.fan.percentage)%" : self.fan.formattedValue
        valueField.toolTip = "\(value)"
        
        let percentage = self.fan.percentage < 0 ? 0 : self.fan.percentage
        self.barView.widthAnchor.constraint(equalToConstant: 110).isActive = true
        self.barView.setValue(ColorValue(Double(percentage) / 100))
        
        row.addArrangedSubview(nameField)
        row.addArrangedSubview(self.barView)
        row.addArrangedSubview(valueField)
        
        self.valueField = valueField
        
        self.addArrangedSubview(row)
    }
    
    private func controllerSetup() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 30))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let container = NSStackView(frame: NSRect(x: 0, y: 4, width: view.frame.width, height: view.frame.height - 8))
        container.wantsLayer = true
        container.layer?.cornerRadius = Constants.Popup.radius
        container.orientation = .horizontal
        container.alignment = .centerY
        container.distribution = .fillProportionally
        container.spacing = 0
        container.wantsLayer = true
        container.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 225/255, green: 225/255, blue: 225/255, alpha: 1)).cgColor
        
        let button: NSButton = NSButton()
        button.isBordered = false
        button.target = self
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Set up FanController"), attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        button.action = #selector(self.checkControllerAvailability)
        self.controllerButton = button
        
        container.addArrangedSubview(button)
        view.addSubview(container)
        
        return view
    }
    
    private func mode() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 44))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let buttons = ModeButtons(frame: NSRect(
            x: 0,
            y: 4,
            width: view.frame.width,
            height: view.frame.height - 8
        ), mode: self.fan.mode)
        buttons.callback = { [weak self] (mode: FanMode) in
            if let fan = self?.fan, mode == .automatic || fan.mode != mode {
                self?.fan.mode = mode
                self?.fan.customMode = mode
                FanController.shared.setFanMode(fan.id, mode: mode.rawValue)
            }
            self?.toggleControlView(mode == .forced)
        }
        buttons.off = { [weak self] in
            if let fan = self?.fan {
                if self?.fan.mode != .forced {
                    self?.fan.mode = .forced
                    FanController.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
                }
                self?.fan.customMode = .forced
                FanController.shared.setFanSpeed(fan.id, speed: 0)
                self?.fan.customSpeed = 0
            }
            self?.toggleControlView(false)
        }
        buttons.turbo = { [weak self] in
            if let fan = self?.fan {
                if self?.fan.mode != .forced {
                    self?.fan.mode = .forced
                    FanController.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
                }
                self?.fan.customMode = .forced
                FanController.shared.setFanSpeed(fan.id, speed: Int(fan.maxSpeed))
                self?.fan.customSpeed = Int(fan.maxSpeed)
            }
            self?.toggleControlView(false)
        }
        
        view.addSubview(buttons)
        self.modeButtons = buttons
        
        return view
    }
    
    private func control() -> NSView {
        let view: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 40))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        view.widthAnchor.constraint(equalToConstant: self.frame.width).isActive = true
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: "control")
        
        view.orientation = .vertical
        view.distribution = .fill
        view.edgeInsets = NSEdgeInsets(top: 0, left: Constants.Popup.margins/2, bottom: Constants.Popup.margins/2, right: Constants.Popup.margins/2)
        
        let slider: NSSlider = NSSlider()
        slider.minValue = self.fan.minSpeed
        slider.maxValue = self.fan.maxSpeed
        slider.doubleValue = self.speed
        slider.isContinuous = true
        slider.action = #selector(self.sliderCallback)
        slider.target = self
        
        let levels: NSStackView = NSStackView()
        levels.heightAnchor.constraint(equalToConstant: 16).isActive = true
        levels.orientation = .horizontal
        levels.distribution = .fill
        
        let minBtn: NSButtonWithPadding = NSButtonWithPadding()
        minBtn.horizontalPadding = 4
        minBtn.title = "\(Int(self.fan.minSpeed))"
        minBtn.toolTip = localizedString("Min")
        minBtn.setButtonType(.toggle)
        minBtn.isBordered = false
        minBtn.target = self
        minBtn.state = .off
        minBtn.action = #selector(self.setMin)
        minBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        minBtn.wantsLayer = true
        minBtn.layer?.cornerRadius = Constants.Popup.radius
        minBtn.layer?.borderWidth = 1
        minBtn.layer?.borderColor = NSColor.lightGray.cgColor
        
        let valueField: NSTextField = TextView()
        valueField.font = NSFont.systemFont(ofSize: 11, weight: .light)
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .center
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let speed = self.fan.customSpeed {
            valueField.stringValue = "\(Int(speed))"
        }
        
        let maxBtn: NSButtonWithPadding = NSButtonWithPadding()
        maxBtn.horizontalPadding = 4
        maxBtn.title = "\(Int(self.fan.maxSpeed))"
        maxBtn.toolTip = localizedString("Max")
        maxBtn.setButtonType(.toggle)
        maxBtn.isBordered = false
        maxBtn.target = self
        maxBtn.state = .off
        maxBtn.wantsLayer = true
        maxBtn.action = #selector(self.setMax)
        maxBtn.layer?.cornerRadius = Constants.Popup.radius
        maxBtn.layer?.borderWidth = 1
        maxBtn.layer?.borderColor = NSColor.lightGray.cgColor
        maxBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        levels.addArrangedSubview(minBtn)
        levels.addArrangedSubview(valueField)
        levels.addArrangedSubview(maxBtn)
        
        view.addArrangedSubview(slider)
        view.addArrangedSubview(levels)
        
        levels.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -Constants.Popup.margins).isActive = true
        
        self.slider = slider
        self.sliderValueField = valueField
        self.minBtn = minBtn
        self.maxBtn = maxBtn
        
        return view
    }
    
    private func toggleControlView(_ state: Bool) {
        guard let view = self.controlView else {
            return
        }
        
        if state {
            self.slider?.doubleValue = self.speed
            if self.speedState {
                self.setSpeed(value: Int(self.speed), then: {
                    DispatchQueue.main.async {
                        self.sliderValueField?.textColor = .systemBlue
                    }
                })
            }
            self.addArrangedSubview(view)
        } else {
            self.sliderValueField?.stringValue = ""
            self.sliderValueField?.textColor = .secondaryLabelColor
            self.minBtn?.state = .off
            self.maxBtn?.state = .off
            view.removeFromSuperview()
        }
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h + self.horizontalMargin))
        self.sizeCallback()
    }
    
    private func setSpeed(value: Int, then: @escaping () -> Void = {}) {
        self.sliderValueField?.stringValue = "\(value) RPM"
        self.sliderValueField?.textColor = .secondaryLabelColor
        self.fan.customSpeed = value
        
        self.debouncer?.cancel()
        
        let task = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                if let id = self?.fan.id {
                    FanController.shared.setFanSpeed(id, speed: value)
                }
                then()
            }
        }
        
        self.debouncer = task
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.3, execute: task)
    }
    
    @objc private func sliderCallback(_ sender: NSSlider) {
        var value = sender.doubleValue
        if value > self.fan.maxSpeed {
            value = self.fan.maxSpeed
        } else if value < self.fan.minSpeed {
            value = self.fan.minSpeed
        }
        
        self.minBtn?.state = .off
        self.maxBtn?.state = .off
        
        self.setSpeed(value: Int(value), then: {
            DispatchQueue.main.async {
                self.slider?.intValue = Int32(value)
                self.sliderValueField?.textColor = .systemBlue
            }
        })
        
        if sender.tag != 4 {
            if self.fan.minSpeed != 0 && self.fan.maxSpeed != 0 && self.fan.maxSpeed != self.fan.minSpeed {
                let percentage = Int((100*(value-self.fan.minSpeed))/(self.fan.maxSpeed - self.fan.minSpeed))
                NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["percentage": percentage])
            } else {
                NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["speed": Int(value)])
            }
        }
    }
    
    @objc func setMin() {
        self.slider?.doubleValue = self.fan.minSpeed
        self.maxBtn?.state = .off
        self.setSpeed(value: Int(self.fan.minSpeed))
        NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["speed": Int(self.fan.minSpeed)])
    }
    
    @objc func setMax() {
        self.slider?.doubleValue = self.fan.maxSpeed
        self.minBtn?.state = .off
        self.setSpeed(value: Int(self.fan.maxSpeed))
        NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["speed": Int(self.fan.maxSpeed)])
    }
    
    @objc private func wakeListener() {
        self.resetModeAfterSleep = true
        
        if self.speedState {
            if let mode = self.willSleepMode, let speed = self.willSleepSpeed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    FanController.shared.setFanMode(self.fan.id, mode: mode.rawValue)
                    self.modeButtons?.setMode(mode)
                    if !mode.isAutomatic {
                        self.setSpeed(value: speed, then: { [weak self] in
                            DispatchQueue.main.async { [weak self] in
                                self?.sliderValueField?.textColor = .systemBlue
                            }
                        })
                    }
                }
            }
            self.willSleepMode = nil
            self.willSleepSpeed = nil
        }
        
        if let value = self.fan.customSpeed, !self.fan.mode.isAutomatic {
            self.setSpeed(value: value, then: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.sliderValueField?.textColor = .systemBlue
                }
            })
        }
    }
    
    @objc private func sleepListener() {
        guard FanController.shared.isActive(), let mode = self.fan.customMode, !mode.isAutomatic else { return }
        
        self.willSleepMode = mode
        self.willSleepSpeed = self.fan.customSpeed
        FanController.shared.setFanMode(fan.id, mode: FanMode.automatic.rawValue)
        self.modeButtons?.setMode(.automatic)
    }
    
    @objc private func syncFanSpeed(_ notification: Notification) {
        guard self.syncState else { return }
        var speed = notification.userInfo?["speed"] as? Int
        if let percentage = notification.userInfo?["percentage"] as? Int {
            speed = ((Int(self.fan.maxSpeed - self.fan.minSpeed)*percentage)/100) + Int(self.fan.minSpeed)
        }
        
        guard let speed, self.fan.customSpeed != speed else { return }
        
        let slider = NSSlider()
        slider.tag = 4
        slider.maxValue = 30000
        slider.intValue = Int32(speed)
        
        self.sliderCallback(slider)
    }
    
    public func update(_ value: Fan) {
        DispatchQueue.main.async(execute: {
            if (self.window?.isVisible ?? false) || !self.ready {
                self.fan.value = value.value
                
                var newValue = ""
                if value.value != 1 {
                    if self.fan.maxSpeed == 1 || self.fan.maxSpeed == 0 {
                        newValue = "\(Int(value.value)) RPM"
                    } else {
                        newValue = self.fanValue == .percentage ? "\(value.percentage)%" : value.formattedValue
                    }
                }
                
                self.valueField?.stringValue = newValue
                self.valueField?.toolTip = value.formattedValue
                
                let percentage = value.percentage < 0 ? 0 : value.percentage
                self.barView.setValue(ColorValue(Double(percentage) / 100))
                
                if self.resetModeAfterSleep && !value.mode.isAutomatic {
                    if self.sliderValueField?.stringValue != "" && self.slider?.doubleValue != value.value {
                        self.slider?.doubleValue = value.value
                        self.sliderValueField?.stringValue = ""
                    }
                    self.modeButtons?.setMode(.forced)
                    self.resetModeAfterSleep = false
                }
                
                self.ready = true
            }
        })
    }
    
    @objc private func checkControllerAvailability() {
        FanController.shared.checkAvailability { [weak self] available in
            DispatchQueue.main.async {
                if available {
                    NotificationCenter.default.post(name: .fanControllerState, object: nil, userInfo: ["state": true])
                } else {
                    self?.showControllerUnavailable()
                    self?.startControllerPolling()
                    NotificationCenter.default.post(name: .fanControllerState, object: nil, userInfo: ["state": false])
                }
            }
        }
    }

    private func showControllerUnavailable() {
        let alert = NSAlert()
        alert.messageText = localizedString("FanController is unavailable")
        alert.informativeText = localizedString("Install and start the standalone FanController, then return to Stats. Stats no longer installs a privileged fan helper.")
        alert.addButton(withTitle: localizedString("Open setup guide"))
        alert.addButton(withTitle: localizedString("Cancel"))
        
        if alert.runModal() == .alertFirstButtonReturn {
            FanController.shared.openSetupGuide()
        }
    }
    
    private func startControllerPolling() {
        self.controllerPollTimer?.invalidate()
        var elapsed: TimeInterval = 0
        self.controllerPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            elapsed += 2
            if FanController.shared.isAvailable {
                timer.invalidate()
                self?.controllerPollTimer = nil
                DispatchQueue.main.async {
                    self?.controllerButton?.title = localizedString("Set up FanController")
                    self?.controllerButton?.action = #selector(FanView.checkControllerAvailability)
                    self?.setupControls(true)
                }
            } else if elapsed >= 60 {
                timer.invalidate()
                self?.controllerPollTimer = nil
            }
        }
    }
    
    private func setupControls(_ isAvailable: Bool? = nil) {
        let controllerState = isAvailable ?? FanController.shared.isAvailable
        self.controllerAvailable = controllerState
        
        if !self.controlState {
            self.controllerSetupView?.removeFromSuperview()
            self.controlView?.removeFromSuperview()
            self.buttonsView?.removeFromSuperview()
        } else {
            if controllerState {
                self.controllerSetupView?.removeFromSuperview()
                if self.fan.maxSpeed != self.fan.minSpeed, let v = self.buttonsView {
                    self.addArrangedSubview(v)
                }
                if self.fan.mode == .forced, let v = self.controlView {
                    self.addArrangedSubview(v)
                }
            } else {
                self.buttonsView?.removeFromSuperview()
                self.controlView?.removeFromSuperview()
                if let v = self.controllerSetupView {
                    self.addArrangedSubview(v)
                }
            }
        }
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h + self.horizontalMargin))
        self.sizeCallback()
    }
    
    @objc private func changeControllerState(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.setupControls(state)
    }
    
    @objc private func recheckControllerState() {
        guard FanController.shared.isAvailable != self.controllerAvailable else { return }
        self.setupControls()
    }
    
    @objc private func controlCallback(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.controlState = state
        self.setupControls()
    }
}

// MARK: - Fan control view (combined)

private final class ReleaseAwareSlider: NSSlider {
    var releaseHandler: ((NSSlider) -> Void)?

    override func mouseDown(with event: NSEvent) {
        // NSSlider tracks the entire drag inside super.mouseDown; returning from
        // it is the reliable indication that the pointer has been released.
        super.mouseDown(with: event)
        self.releaseHandler?(self)
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        self.releaseHandler?(self)
    }
}

/// Combined fan control: read-only rows for every fan plus a single shared
/// control block (Automatic | Custom | Manual, one slider, profile picker).
internal class FanControlView: NSStackView {
    private var modeGeneration = 0
    private var wakeTask: DispatchWorkItem?
    public var sizeCallback: (() -> Void)

    internal let fans: [Fan]
    internal private(set) var mode: FanMode

    private var ready: Bool = false
    private var controllerSetupView: NSView? = nil
    private var controlView: NSView? = nil
    private var buttonsView: NSView? = nil
    private var profileRow: NSView? = nil

    private var valueFields: [Int: NSTextField] = [:]
    private var barViews: [Int: BarChartView] = [:]
    private var sliderValueField: NSTextField? = nil

    private var slider: NSSlider? = nil
    private var modeButtons: ModeButtons? = nil
    private var profilePicker: NSPopUpButton? = nil
    private var debouncer: DispatchWorkItem? = nil

    private var minBtn: NSButton? = nil
    private var maxBtn: NSButton? = nil

    private var speedState: Bool { Store.shared.bool(key: "Sensors_speed", defaultValue: false) }
    private var controlState: Bool
    private var controllerAvailable: Bool = false
    private var controllerButton: NSButton? = nil
    private var controllerPollTimer: Timer? = nil
    private var resetModeAfterSleep: Bool = false

    private var fanValue: FanValue {
        FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.percentage.rawValue)) ?? .percentage
    }

    private var minSpeed: Double { self.fans.map({ $0.minSpeed }).min() ?? 0 }
    private var maxSpeed: Double { self.fans.map({ $0.maxSpeed }).max() ?? 0 }

    private var storedMode: FanMode {
        get {
            let raw = Store.shared.int(key: "Sensors_fanMode", defaultValue: -1)
            if raw >= 0, let mode = FanMode(rawValue: raw) { return mode }
            return self.fans.first?.mode ?? .automatic
        }
        set { Store.shared.set(key: "Sensors_fanMode", value: newValue.rawValue) }
    }
    private var storedSpeed: Int? {
        get {
            if Store.shared.exist(key: "Sensors_fanSpeed") {
                return Store.shared.int(key: "Sensors_fanSpeed", defaultValue: 0)
            }
            return nil
        }
        set {
            if let value = newValue {
                Store.shared.set(key: "Sensors_fanSpeed", value: value)
            } else {
                Store.shared.remove("Sensors_fanSpeed")
            }
        }
    }

    private var horizontalMargin: CGFloat {
        self.edgeInsets.top + self.edgeInsets.bottom + (self.spacing*CGFloat(self.arrangedSubviews.count))
    }

    private var willSleepMode: FanMode? = nil
    private var willSleepSpeed: Int? = nil

    public init(fans: [Fan], width: CGFloat, callback: @escaping (() -> Void)) {
        self.fans = fans
        self.sizeCallback = callback
        self.controlState = Store.shared.bool(key: "Sensors_fanControl", defaultValue: true)
        let storedRaw = Store.shared.int(key: "Sensors_fanMode", defaultValue: -1)
        self.mode = storedRaw >= 0 ? (FanMode(rawValue: storedRaw) ?? .automatic) : (fans.first?.mode ?? .automatic)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))

        self.controllerSetupView = self.controllerSetup()
        self.controlView = self.control()
        self.buttonsView = self.modeButtonsView()
        self.profileRow = self.profile()

        self.orientation = .vertical
        self.alignment = .centerX
        self.distribution = .fillProportionally
        self.spacing = 1
        self.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius

        self.nameAndSpeed()
        self.setupControls()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeListener), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepListener), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.changeControllerState), name: .fanControllerState, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.controlCallback), name: .toggleFanControl, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.recheckControllerState), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.profilesChanged), name: .fanCurveProfilesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.fanControlUnavailable), name: Notification.Name("SensorsFanControlUnavailable"), object: nil)

        if self.mode == .custom {
            FanCurveController.shared.setEnabled(true)
            FanCurveController.shared.reapply()
        } else if self.mode == .forced && self.speedState {
            if let speed = self.storedSpeed {
                self.setSpeed(value: speed, delay: 1)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.controllerPollTimer?.invalidate()
        self.debouncer?.cancel()
        self.wakeTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    private func nameAndSpeed() {
        self.fans.forEach { fan in
            let row: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 16))
            row.widthAnchor.constraint(equalToConstant: self.frame.width).isActive = true
            row.heightAnchor.constraint(equalToConstant: row.bounds.height).isActive = true
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 0

            let nameField: NSTextField = TextView()
            nameField.stringValue = fan.name
            nameField.toolTip = fan.key
            nameField.cell?.truncatesLastVisibleLine = true

            let valueField: NSTextField = TextView()
            valueField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            valueField.alignment = .right
            valueField.stringValue = self.fanValue == .percentage ? "\(fan.percentage)%" : fan.formattedValue
            valueField.toolTip = "\(fan.value)"

            let barView: BarChartView = BarChartView(size: 6, horizontal: true)
            barView.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let percentage = fan.percentage < 0 ? 0 : fan.percentage
            barView.setValue(ColorValue(Double(percentage) / 100))

            row.addArrangedSubview(nameField)
            row.addArrangedSubview(barView)
            row.addArrangedSubview(valueField)

            self.valueFields[fan.id] = valueField
            self.barViews[fan.id] = barView

            self.addArrangedSubview(row)
        }
    }

    private func controllerSetup() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 30))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true

        let container = NSStackView(frame: NSRect(x: 0, y: 4, width: view.frame.width, height: view.frame.height - 8))
        container.wantsLayer = true
        container.layer?.cornerRadius = Constants.Popup.radius
        container.orientation = .horizontal
        container.alignment = .centerY
        container.distribution = .fillProportionally
        container.spacing = 0
        container.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 225/255, green: 225/255, blue: 225/255, alpha: 1)).cgColor

        let button: NSButton = NSButton()
        button.isBordered = false
        button.target = self
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Set up FanController"), attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        button.action = #selector(self.checkControllerAvailability)
        self.controllerButton = button

        container.addArrangedSubview(button)
        view.addSubview(container)

        return view
    }

    private func modeButtonsView() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 44))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true

        let buttons = ModeButtons(frame: NSRect(
            x: 0,
            y: 4,
            width: view.frame.width,
            height: view.frame.height - 8
        ), mode: self.mode)
        buttons.callback = { [weak self] (mode: FanMode) in
            self?.applyMode(mode)
        }
        buttons.off = { [weak self] in
            self?.applyOff()
        }
        buttons.turbo = { [weak self] in
            self?.applyTurbo()
        }

        view.addSubview(buttons)
        self.modeButtons = buttons

        return view
    }

    private func applyMode(_ mode: FanMode) {
        guard mode.isAutomatic || FanCurveController.shared.pollingAvailable else {
            self.modeButtons?.setMode(.automatic)
            return
        }
        self.modeGeneration += 1
        self.wakeTask?.cancel()
        self.debouncer?.cancel()
        self.mode = mode
        self.storedMode = mode
        self.fans.forEach { fan in
            Store.shared.remove("fan_\(fan.id)_mode")
            Store.shared.remove("fan_\(fan.id)_speed")
        }

        switch mode {
        case .automatic:
            FanCurveController.shared.setEnabled(false)
            self.fans.forEach { FanController.shared.setFanMode($0.id, mode: FanMode.automatic.rawValue) }
            FanController.shared.resetFanControl()
        case .forced:
            FanCurveController.shared.setEnabled(false)
        case .custom:
            FanCurveController.shared.setEnabled(false)
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .custom else { return }
                FanCurveController.shared.setEnabled(true)
                FanCurveController.shared.reapply()
            }
            self.debouncer = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
        default:
            break
        }

        self.toggleControlView(mode == .forced)
        self.toggleProfileRow(mode == .custom)
    }

    private func applyOff() {
        guard FanCurveController.shared.pollingAvailable else { self.modeButtons?.setMode(.automatic); return }
        self.modeGeneration += 1
        self.wakeTask?.cancel()
        self.debouncer?.cancel()
        self.mode = .forced
        self.storedMode = .forced
        FanCurveController.shared.setEnabled(false)
        FanController.shared.setFanSpeeds(Dictionary(uniqueKeysWithValues: self.fans.map { ($0.id, 0) }))
        self.storedSpeed = 0
        self.toggleControlView(false)
        self.toggleProfileRow(false)
    }

    private func applyTurbo() {
        guard FanCurveController.shared.pollingAvailable else { self.modeButtons?.setMode(.automatic); return }
        self.modeGeneration += 1
        self.wakeTask?.cancel()
        self.debouncer?.cancel()
        self.mode = .forced
        self.storedMode = .forced
        FanCurveController.shared.setEnabled(false)
        FanController.shared.setFanSpeeds(Dictionary(uniqueKeysWithValues: self.fans.map { ($0.id, Int($0.maxSpeed)) }))
        self.storedSpeed = Int(self.maxSpeed)
        self.toggleControlView(false)
        self.toggleProfileRow(false)
    }

    private func control() -> NSView {
        let view: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 40))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        view.widthAnchor.constraint(equalToConstant: self.frame.width).isActive = true
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: "control")

        view.orientation = .vertical
        view.distribution = .fill
        view.edgeInsets = NSEdgeInsets(top: 0, left: Constants.Popup.margins/2, bottom: Constants.Popup.margins/2, right: Constants.Popup.margins/2)

        let slider = ReleaseAwareSlider()
        slider.minValue = self.minSpeed
        slider.maxValue = self.maxSpeed
        slider.doubleValue = Double(self.storedSpeed ?? Int(self.fans.first?.value ?? 0))
        slider.isContinuous = true
        slider.action = #selector(self.sliderCallback)
        slider.target = self
        slider.releaseHandler = { [weak self, weak slider] _ in
            guard let self, let slider else { return }
            self.snapSlider(slider)
        }

        let levels: NSStackView = NSStackView()
        levels.heightAnchor.constraint(equalToConstant: 16).isActive = true
        levels.orientation = .horizontal
        levels.distribution = .fill

        let minBtn: NSButtonWithPadding = NSButtonWithPadding()
        minBtn.horizontalPadding = 4
        minBtn.title = "\(Int(self.minSpeed))"
        minBtn.toolTip = localizedString("Min")
        minBtn.setButtonType(.toggle)
        minBtn.isBordered = false
        minBtn.target = self
        minBtn.state = .off
        minBtn.action = #selector(self.setMin)
        minBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        minBtn.wantsLayer = true
        minBtn.layer?.cornerRadius = Constants.Popup.radius
        minBtn.layer?.borderWidth = 1
        minBtn.layer?.borderColor = NSColor.lightGray.cgColor

        let valueField: NSTextField = TextView()
        valueField.font = NSFont.systemFont(ofSize: 11, weight: .light)
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .center
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let speed = self.storedSpeed {
            valueField.stringValue = "\(Int(speed))"
        }

        let maxBtn: NSButtonWithPadding = NSButtonWithPadding()
        maxBtn.horizontalPadding = 4
        maxBtn.title = "\(Int(self.maxSpeed))"
        maxBtn.toolTip = localizedString("Max")
        maxBtn.setButtonType(.toggle)
        maxBtn.isBordered = false
        maxBtn.target = self
        maxBtn.state = .off
        maxBtn.wantsLayer = true
        maxBtn.action = #selector(self.setMax)
        maxBtn.layer?.cornerRadius = Constants.Popup.radius
        maxBtn.layer?.borderWidth = 1
        maxBtn.layer?.borderColor = NSColor.lightGray.cgColor
        maxBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        levels.addArrangedSubview(minBtn)
        levels.addArrangedSubview(valueField)
        levels.addArrangedSubview(maxBtn)

        view.addArrangedSubview(slider)
        view.addArrangedSubview(levels)

        levels.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -Constants.Popup.margins).isActive = true

        self.slider = slider
        self.sliderValueField = valueField
        self.minBtn = minBtn
        self.maxBtn = maxBtn

        return view
    }

    private func profile() -> NSView {
        let view: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 24))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        view.orientation = .horizontal
        view.alignment = .centerY
        view.distribution = .fillProportionally
        view.spacing = 4
        view.edgeInsets = .init(top: 0, left: Constants.Popup.margins/2, bottom: 0, right: Constants.Popup.margins/2)

        let picker: NSPopUpButton = NSPopUpButton()
        picker.target = self
        picker.action = #selector(self.profileChanged(_:))
        picker.controlSize = .small
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.profilePicker = picker
        self.refreshProfilePicker()

        let edit: NSButton = NSButton(title: localizedString("Configs"), target: self, action: #selector(self.openFanCurveConfig))
        edit.isBordered = false
        edit.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        edit.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        view.addArrangedSubview(picker)
        view.addArrangedSubview(edit)

        return view
    }

    private func refreshProfilePicker() {
        guard let picker = self.profilePicker else { return }
        let names = FanCurveController.shared.profileNames
        let active = FanCurveController.shared.activeProfileName
        let previous = picker.selectedItem?.title

        picker.removeAllItems()
        names.forEach { picker.addItem(withTitle: $0) }
        if let active, let idx = names.firstIndex(of: active) {
            picker.selectItem(at: idx)
        } else if let previous, let idx = names.firstIndex(of: previous) {
            picker.selectItem(at: idx)
        }
    }

    @objc private func profilesChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshProfilePicker()
        }
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let name = sender.selectedItem?.title else { return }
        FanCurveController.shared.selectProfile(name)
    }

    @objc private func openFanCurveConfig() {
        FanCurveController.shared.openConfig()
    }

    private func toggleControlView(_ state: Bool) {
        guard let view = self.controlView else { return }

        if state {
            self.slider?.doubleValue = Double(self.storedSpeed ?? Int(self.fans.first?.value ?? 0))
            self.setSpeed(value: Int(self.slider?.doubleValue ?? 0), delay: 1, then: { [weak self] in
                self?.sliderValueField?.textColor = .systemBlue
            })
            self.addArrangedSubview(view)
        } else {
            self.sliderValueField?.stringValue = ""
            self.sliderValueField?.textColor = .secondaryLabelColor
            self.minBtn?.state = .off
            self.maxBtn?.state = .off
            view.removeFromSuperview()
        }

        self.refreshSize()
    }

    private func toggleProfileRow(_ state: Bool) {
        guard let view = self.profileRow else { return }

        if state {
            self.refreshProfilePicker()
            self.addArrangedSubview(view)
        } else {
            view.removeFromSuperview()
        }

        self.refreshSize()
    }

    private func setSpeed(value: Int, delay: TimeInterval = 0.3, then: @escaping () -> Void = {}) {
        self.modeGeneration += 1
        self.sliderValueField?.stringValue = "\(value) RPM"
        self.sliderValueField?.textColor = .secondaryLabelColor
        self.storedSpeed = value

        self.debouncer?.cancel()

        let generation = self.modeGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .forced, self.modeGeneration == generation else { return }
            let targets = Dictionary(uniqueKeysWithValues: self.fans.map { fan in
                let target = min(Int(fan.maxSpeed), max(Int(fan.minSpeed), value))
                return (fan.id, target)
            })
            FanController.shared.setFanSpeeds(targets) { [weak self] success in
                guard let self, success, self.mode == .forced, self.modeGeneration == generation else { return }
                then()
            }
        }

        self.debouncer = task
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay, execute: task)
    }

    @objc private func sliderCallback(_ sender: NSSlider) {
        var value = sender.doubleValue
        if value > self.maxSpeed {
            value = self.maxSpeed
        } else if value < self.minSpeed {
            value = self.minSpeed
        }

        self.minBtn?.state = .off
        self.maxBtn?.state = .off

        self.setSpeed(value: Int(value), then: { [weak self] in
            self?.slider?.intValue = Int32(value)
            self?.sliderValueField?.textColor = .systemBlue
        })
    }

    private func snapSlider(_ sender: NSSlider) {
        let speed = FanSliderController.shared.snappedSpeed(
            Int(sender.doubleValue.rounded()),
            minimum: Int(self.minSpeed),
            maximum: Int(self.maxSpeed)
        )
        sender.integerValue = speed
        self.setSpeed(value: speed) { [weak self] in
            self?.sliderValueField?.textColor = .systemBlue
        }
    }

    @objc func setMin(_ sender: NSButton) {
        self.slider?.doubleValue = self.minSpeed
        self.maxBtn?.state = .off
        self.setSpeed(value: Int(self.minSpeed))
    }

    @objc func setMax(_ sender: NSButton) {
        self.slider?.doubleValue = self.maxSpeed
        self.minBtn?.state = .off
        self.setSpeed(value: Int(self.maxSpeed))
    }

    @objc private func wakeListener(aNotification: NSNotification) {
        self.resetModeAfterSleep = true
        self.wakeTask?.cancel()
        let generation = self.modeGeneration
        let mode = self.willSleepMode
        let speed = self.willSleepSpeed
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.modeGeneration == generation, let mode,
                  mode == .custom || self.speedState else { return }
            if mode == .forced, let speed { self.storedSpeed = speed }
            self.modeButtons?.setMode(mode)
        }
        self.wakeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
        self.willSleepMode = nil
        self.willSleepSpeed = nil
    }

    @objc private func sleepListener(aNotification: NSNotification) {
        guard FanController.shared.isActive(), !self.mode.isAutomatic else { return }

        self.debouncer?.cancel()
        self.wakeTask?.cancel()
        self.modeGeneration += 1
        self.willSleepMode = self.mode
        self.willSleepSpeed = self.storedSpeed ?? Int(self.slider?.doubleValue ?? 0)
        FanCurveController.shared.setEnabled(false)
        FanCurveController.shared.invalidateSamples()
        self.fans.forEach { FanController.shared.setFanMode($0.id, mode: FanMode.automatic.rawValue) }
        FanController.shared.resetFanControl()
        if self.mode != .custom {
            self.modeButtons?.setMode(.automatic)
        }
    }

    @objc private func fanControlUnavailable() {
        FanCurveController.shared.setEnabled(false)
        self.willSleepMode = nil
        self.willSleepSpeed = nil
        self.modeButtons?.setMode(.automatic)
    }

    public func update(_ value: Fan) {
        DispatchQueue.main.async(execute: { [weak self] in
            guard let self else { return }
            if (self.window?.isVisible ?? false) || !self.ready {
                self.updateFanRow(value)
                self.ready = true
            }
        })
    }

    private func updateFanRow(_ value: Fan) {
        guard let valueField = self.valueFields[value.id], let barView = self.barViews[value.id] else { return }

        var newValue = ""
        if value.value != 1 {
            if value.maxSpeed == 1 || value.maxSpeed == 0 {
                newValue = "\(Int(value.value)) RPM"
            } else {
                newValue = self.fanValue == .percentage ? "\(value.percentage)%" : value.formattedValue
            }
        }

        valueField.stringValue = newValue
        valueField.toolTip = value.formattedValue

        let percentage = value.percentage < 0 ? 0 : value.percentage
        barView.setValue(ColorValue(Double(percentage) / 100))
    }

    @objc private func checkControllerAvailability(_ sender: NSButton) {
        FanController.shared.checkAvailability { [weak self] available in
            DispatchQueue.main.async {
                if available {
                    NotificationCenter.default.post(name: .fanControllerState, object: nil, userInfo: ["state": true])
                } else {
                    self?.showControllerUnavailable()
                    self?.startControllerPolling()
                    NotificationCenter.default.post(name: .fanControllerState, object: nil, userInfo: ["state": false])
                }
            }
        }
    }

    private func showControllerUnavailable() {
        let alert = NSAlert()
        alert.messageText = localizedString("FanController is unavailable")
        alert.informativeText = localizedString("Install and start the standalone FanController, then return to Stats. Stats no longer installs a privileged fan helper.")
        alert.addButton(withTitle: localizedString("Open setup guide"))
        alert.addButton(withTitle: localizedString("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn {
            FanController.shared.openSetupGuide()
        }
    }

    private func startControllerPolling() {
        self.controllerPollTimer?.invalidate()
        var elapsed: TimeInterval = 0
        self.controllerPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            elapsed += 2
            if FanController.shared.isAvailable {
                timer.invalidate()
                self?.controllerPollTimer = nil
                DispatchQueue.main.async {
                    self?.controllerButton?.title = localizedString("Set up FanController")
                    self?.controllerButton?.action = #selector(FanControlView.checkControllerAvailability)
                    self?.setupControls(true)
                }
            } else if elapsed >= 60 {
                timer.invalidate()
                self?.controllerPollTimer = nil
            }
        }
    }

    private func setupControls(_ isAvailable: Bool? = nil) {
        let controllerState = isAvailable ?? FanController.shared.isAvailable
        self.controllerAvailable = controllerState

        if !self.controlState {
            self.controllerSetupView?.removeFromSuperview()
            self.controlView?.removeFromSuperview()
            self.buttonsView?.removeFromSuperview()
            self.profileRow?.removeFromSuperview()
        } else {
            if controllerState {
                self.controllerSetupView?.removeFromSuperview()
                if self.minSpeed != self.maxSpeed, let v = self.buttonsView {
                    self.addArrangedSubview(v)
                }
                if self.mode == .forced, let v = self.controlView {
                    self.addArrangedSubview(v)
                }
                if self.mode == .custom, let v = self.profileRow {
                    self.refreshProfilePicker()
                    self.addArrangedSubview(v)
                }
            } else {
                self.buttonsView?.removeFromSuperview()
                self.controlView?.removeFromSuperview()
                self.profileRow?.removeFromSuperview()
                if let v = self.controllerSetupView {
                    self.addArrangedSubview(v)
                }
            }
        }

        self.refreshSize()
    }

    private func refreshSize() {
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h + self.horizontalMargin))
        self.sizeCallback()
    }

    @objc private func changeControllerState(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.setupControls(state)
    }

    @objc private func recheckControllerState() {
        guard FanController.shared.isAvailable != self.controllerAvailable else { return }
        self.setupControls()
    }

    @objc private func controlCallback(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.controlState = state
        self.setupControls()
    }
}

private class ModeButtons: NSStackView {
    public var callback: (FanMode) -> Void = {_ in }
    public var customCallback: (() -> Void) = {}
    public var turbo: () -> Void = {}
    public var off: () -> Void = {}
    
    private var fansSyncState: Bool { Store.shared.bool(key: "Sensors_fansSync", defaultValue: false) }
    
    private var modes: ModeSwitch
    
    private var offBtn: NSButton
    private var turboBtn: NSButton
    
    public init(frame: NSRect, mode: FanMode) {
        self.modes = .init(mode)
        
        self.offBtn = NSButton(image: iconFromSymbol(name: "nosign", scale: .medium), target: nil, action: #selector(offMode))
        self.turboBtn = NSButton(image: iconFromSymbol(name: "snowflake", scale: .large), target: nil, action: #selector(turboMode))
        
        super.init(frame: frame)
        
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fillProportionally
        self.spacing = 0
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        self.edgeInsets = .init(top: 0, left: Constants.Popup.margins/2, bottom: 0, right: Constants.Popup.margins/2)
        
        self.modes.autoCallback = { [weak self] in
            if let self {
                self.offBtn.state = .off
                self.turboBtn.state = .off
                self.callback(.automatic)
            }
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "automatic"])
            NotificationCenter.default.post(name: .checkFanModes, object: nil)
        }
        self.modes.manualCallback = { [weak self] in
            if let self {
                self.offBtn.state = .off
                self.turboBtn.state = .off
                self.callback(.forced)
            }
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "forced"])
        }
        self.modes.customCallback = { [weak self] in
            if let self {
                self.offBtn.state = .off
                self.turboBtn.state = .off
                self.callback(.custom)
            }
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "custom"])
        }
        
        self.offBtn.setButtonType(.toggle)
        self.offBtn.isBordered = false
        self.offBtn.target = self
        
        self.turboBtn.setButtonType(.toggle)
        self.turboBtn.isBordered = false
        self.turboBtn.target = self
        
        self.addArrangedSubview(modes)
        self.addArrangedSubview(self.offBtn)
        self.addArrangedSubview(self.turboBtn)
        
        NSLayoutConstraint.activate([
            self.modes.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -Constants.Popup.margins),
            self.offBtn.widthAnchor.constraint(equalToConstant: 26),
            self.offBtn.heightAnchor.constraint(equalToConstant: self.frame.height),
            self.turboBtn.widthAnchor.constraint(equalToConstant: 26),
            self.turboBtn.heightAnchor.constraint(equalToConstant: self.frame.height)
        ])
        
        NotificationCenter.default.addObserver(self, selector: #selector(syncFanMode), name: .syncFansControl, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }
    
    @objc private func offMode(_ sender: NSButton) {
        if sender.state.rawValue == 0 {
            self.offBtn.state = .on
            return
        }
        
        if !Store.shared.bool(key: "Sensors_turnOffFanAlert", defaultValue: false) {
            let alert = NSAlert()
            alert.messageText = localizedString("Turn off fan")
            alert.informativeText = localizedString("You are going to turn off the fan. This is not recommended action that can damage your mac, are you sure you want to do that?")
            alert.showsSuppressionButton = true
            alert.addButton(withTitle: localizedString("Turn off"))
            alert.addButton(withTitle: localizedString("Cancel"))
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let suppressionButton = alert.suppressionButton, suppressionButton.state == .on {
                    Store.shared.set(key: "Sensors_turnOffFanAlert", value: true)
                }
                self.toggleOffMode(sender)
            } else {
                self.offBtn.state = .off
            }
        } else {
            self.toggleOffMode(sender)
        }
    }
    
    private func toggleOffMode(_ sender: NSButton) {
        self.modes.change()
        self.offBtn.state = .on
        self.turboBtn.state = .off
        self.off()
        
        if sender.tag != 4 {
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "off"])
        }
    }
    
    @objc private func turboMode(_ sender: NSButton) {
        if sender.state.rawValue == 0 {
            self.turboBtn.state = .on
            return
        }
        
        self.modes.change()
        self.offBtn.state = .off
        self.turboBtn.state = .on
        self.turbo()
        
        if sender.tag != 4 {
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "turbo"])
        }
    }
    
    @objc private func syncFanMode(_ notification: Notification) {
        guard let mode = notification.userInfo?["mode"] as? String, self.fansSyncState else {
            return
        }
        
        if mode == "automatic" {
            self.setMode(.automatic)
        } else if mode == "forced" {
            self.setMode(.forced)
        } else if mode == "custom" {
            self.setMode(.custom)
        } else if mode == "off" {
            let btn = NSButton()
            btn.state = .on
            btn.tag = 4
            self.offMode(btn)
        } else if mode == "turbo" {
            let btn = NSButton()
            btn.state = .on
            btn.tag = 4
            self.turboMode(btn)
        }
    }
    
    public func setMode(_ mode: FanMode) {
        if mode.isAutomatic {
            self.modes.change(auto: true)
            self.offBtn.state = .off
            self.turboBtn.state = .off
            self.callback(.automatic)
        } else if mode == .forced {
            self.modes.change(manual: true)
            self.offBtn.state = .off
            self.turboBtn.state = .off
            self.callback(.forced)
        } else if mode == .custom {
            self.modes.change(custom: true)
            self.offBtn.state = .off
            self.turboBtn.state = .off
            self.callback(.custom)
        }
    }
}

private class ModeSwitch: NSStackView {
    public var autoCallback: (() -> Void)?
    public var manualCallback: (() -> Void)?
    public var customCallback: (() -> Void)?
    
    private var autoBtn: NSButton = {
        let button: NSButton = NSButton(title: localizedString("Automatic"), target: nil, action: #selector(autoMode))
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Constants.Popup.radius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Automatic"), attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        return button
    }()
    
    private var manualBtn: NSButton = {
        let button: NSButton = NSButton(title: localizedString("Manual"), target: nil, action: #selector(manualMode))
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Constants.Popup.radius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Manual"), attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        return button
    }()

    private var customBtn: NSButton = {
        let button: NSButton = NSButton(title: localizedString("Custom"), target: nil, action: #selector(customMode))
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Constants.Popup.radius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Custom"), attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        return button
    }()
    
    private var selectedColor: CGColor {
        (isDarkMode ? NSColor(red: 95/255, green: 95/255, blue: 95/255, alpha: 1) : .textBackgroundColor).cgColor
    }
    
    init(_ mode: FanMode) {
        super.init(frame: .zero)
        
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fillEqually
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        self.spacing = 0
        self.edgeInsets = .init(top: 2, left: 2, bottom: 2, right: 2)
        
        self.autoBtn.target = self
        self.autoBtn.state = mode.isAutomatic ? .on : .off
        self.autoBtn.layer?.backgroundColor = mode.isAutomatic ? self.selectedColor : NSColor.clear.cgColor
        
        self.manualBtn.target = self
        self.manualBtn.state = mode == .forced ? .on : .off
        self.manualBtn.layer?.backgroundColor = mode == .forced ? self.selectedColor : NSColor.clear.cgColor

        self.customBtn.target = self
        self.customBtn.state = mode == .custom ? .on : .off
        self.customBtn.layer?.backgroundColor = mode == .custom ? self.selectedColor : NSColor.clear.cgColor
        
        self.addArrangedSubview(self.autoBtn)
        self.addArrangedSubview(self.customBtn)
        self.addArrangedSubview(self.manualBtn)
        
        NSLayoutConstraint.activate([
            self.autoBtn.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -4),
            self.customBtn.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -4),
            self.manualBtn.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -4)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 225/255, green: 225/255, blue: 225/255, alpha: 1)).cgColor
        self.autoBtn.layer?.backgroundColor = self.autoBtn.state == .on ? self.selectedColor : NSColor.clear.cgColor
        self.customBtn.layer?.backgroundColor = self.customBtn.state == .on ? self.selectedColor : NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = self.manualBtn.state == .on ? self.selectedColor : NSColor.clear.cgColor
    }
    
    public func change(auto: Bool = false, manual: Bool = false, custom: Bool = false) {
        self.autoBtn.state = auto ? .on : .off
        self.customBtn.state = custom ? .on : .off
        self.manualBtn.state = manual ? .on : .off
        
        self.autoBtn.layer?.backgroundColor = auto ? self.selectedColor : NSColor.clear.cgColor
        self.customBtn.layer?.backgroundColor = custom ? self.selectedColor : NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = manual ? self.selectedColor : NSColor.clear.cgColor
    }
    
    @objc private func autoMode() {
        self.autoBtn.state = .on
        self.customBtn.state = .off
        self.manualBtn.state = .off
        
        self.autoBtn.layer?.backgroundColor = self.selectedColor
        self.customBtn.layer?.backgroundColor = NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = NSColor.clear.cgColor
        
        self.autoCallback?()
    }

    @objc private func customMode() {
        self.autoBtn.state = .off
        self.customBtn.state = .on
        self.manualBtn.state = .off

        self.autoBtn.layer?.backgroundColor = NSColor.clear.cgColor
        self.customBtn.layer?.backgroundColor = self.selectedColor
        self.manualBtn.layer?.backgroundColor = NSColor.clear.cgColor

        self.customCallback?()
    }
    
    @objc private func manualMode() {
        self.autoBtn.state = .off
        self.customBtn.state = .off
        self.manualBtn.state = .on
        
        self.autoBtn.layer?.backgroundColor = NSColor.clear.cgColor
        self.customBtn.layer?.backgroundColor = NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = self.selectedColor
        
        self.manualCallback?()
    }
}
