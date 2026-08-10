//
//  FanCurve.swift
//  Sensors
//
//  Drives both fans from a JSON config file with multiple profiles. The config
//  lives at ~/Library/Application Support/Stats/fan-curve.json and is re-read on
//  every module tick, so edits hot-reload within a tick.
//

import Cocoa
import Kit

public class FanCurveController {
    public static let shared = FanCurveController()

    private var enabled = false
    private var sensors: [Sensor_p] = []
    private var lastTargets: [Int: Int] = [:]
    private var lastFailureReset = false

    public private(set) var profileNames: [String] = []
    public private(set) var activeProfileName: String? = nil

    public var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Stats").appendingPathComponent("fan-curve.json")
    }

    public func setEnabled(_ value: Bool) {
        guard self.enabled != value else { return }
        self.enabled = value
        self.lastTargets = [:]
        if !value {
            self.lastFailureReset = false
        }
    }

    /// Clear applied targets so the next tick rewrites the fans (used after wake
    /// or when switching profiles).
    public func reapply() {
        self.lastTargets = [:]
        self.update(self.sensors)
    }

    public func update(_ sensors: [Sensor_p]) {
        self.sensors = sensors
        guard self.enabled else { return }

        let config: FanCurveConfig?
        if let data = try? Data(contentsOf: self.configURL) {
            config = FanCurveConfig.parse(data)
        } else {
            config = nil
        }

        guard let config, let profile = config.active, !profile.rules.isEmpty else {
            // Missing or invalid config: stop custom control and restore automatic.
            if !self.lastFailureReset {
                self.lastFailureReset = true
                self.lastTargets = [:]
                self.resetAutomatic()
            }
            self.publish(profileNames: [], active: nil)
            return
        }
        self.lastFailureReset = false

        var keys: [String: Double] = [:]
        var names: [String: Double] = [:]
        sensors.forEach { s in
            guard s.type == .temperature else { return }
            keys[s.key.lowercased()] = s.value
            names[s.name.lowercased()] = s.value
        }

        let target = FanCurveMath.targetSpeed(rules: profile.rules, keys: keys, names: names)
        let fans = sensors.filter({ $0.type == .fan && !$0.isComputed }).compactMap({ $0 as? Fan })

        if let target, !fans.isEmpty {
            fans.forEach { fan in
                let clamped = min(Int(fan.maxSpeed), max(Int(fan.minSpeed), target))
                if self.lastTargets[fan.id] != clamped {
                    SMCHelper.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
                    SMCHelper.shared.setFanSpeed(fan.id, speed: clamped)
                    self.lastTargets[fan.id] = clamped
                }
            }
        } else if !self.lastFailureReset {
            self.lastFailureReset = true
            self.lastTargets = [:]
            self.resetAutomatic()
        }

        self.publish(profileNames: config.profiles.map({ $0.name }), active: config.activeProfile)
    }

    public func selectProfile(_ name: String) {
        guard var config = self.currentConfig() else { return }
        guard config.profiles.contains(where: { $0.name == name }) else { return }
        config.activeProfile = name
        self.write(config)
        self.publish(profileNames: config.profiles.map({ $0.name }), active: name)
        self.reapply()
    }

    public func openConfig() {
        let fm = FileManager.default
        let dir = self.configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: self.configURL.path) {
            self.write(Self.defaultConfig)
        }
        NSWorkspace.shared.open(self.configURL)
    }

    public func resetAutomatic() {
        guard SMCHelper.shared.isActive() else { return }
        SMCHelper.shared.resetFanControl()
    }

    private func currentConfig() -> FanCurveConfig? {
        guard let data = try? Data(contentsOf: self.configURL) else { return nil }
        return FanCurveConfig.parse(data)
    }

    private func write(_ config: FanCurveConfig) {
        let fm = FileManager.default
        let dir = self.configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = config.encoded() else { return }
        try? data.write(to: self.configURL)
    }

    private func publish(profileNames: [String], active: String?) {
        if self.profileNames != profileNames {
            self.profileNames = profileNames
            NotificationCenter.default.post(name: .fanCurveProfilesChanged, object: nil)
        }
        self.activeProfileName = active
    }

    private static let defaultConfig = FanCurveConfig(
        activeProfile: "Balanced",
        profiles: [
            FanCurveProfile(name: "Quiet", rules: [
                FanCurveRule(sensorName: "Average CPU", points: [
                    FanCurvePoint(temp: 60, speed: 2317),
                    FanCurvePoint(temp: 85, speed: 3500)
                ])
            ]),
            FanCurveProfile(name: "Balanced", rules: [
                FanCurveRule(sensorName: "Average CPU", points: [
                    FanCurvePoint(temp: 55, speed: 2400),
                    FanCurvePoint(temp: 75, speed: 4500),
                    FanCurvePoint(temp: 95, speed: 7826)
                ]),
                FanCurveRule(sensor: "Tp04", points: [
                    FanCurvePoint(temp: 50, speed: 2400),
                    FanCurvePoint(temp: 90, speed: 7000)
                ])
            ]),
            FanCurveProfile(name: "Performance", rules: [
                FanCurveRule(sensorName: "Hottest CPU", points: [
                    FanCurvePoint(temp: 45, speed: 3500),
                    FanCurvePoint(temp: 70, speed: 7000)
                ])
            ])
        ]
    )
}
