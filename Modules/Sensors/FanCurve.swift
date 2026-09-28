//
//  FanCurve.swift
//  Sensors
//
//  Drives both fans from a JSON config file with multiple profiles. Each profile
//  has separate temperatureRules, usageRules, and appRules lists. The config lives at
//  ~/Library/Application Support/Stats/fan-curve.json and is re-read on every
//  module tick, so edits hot-reload within a tick.
//
//  The final target is always the highest of: the interpolated curve speeds and
//  any appRules entries in the active profile whose app is currently running.
//

import Cocoa
import Kit

public class FanCurveController {
    public static let shared = FanCurveController()

    private var enabled = false
    private var sensors: [Sensor_p] = []
    private var lastTargets: [Int: Int] = [:]
    private var generation = 0
    private var pending: Set<Int> = []
    private var lastApplied: [Int: TimeInterval] = [:]
    private var invalidTemperatures: Set<String> = []
    private var sampledAt: TimeInterval = 0
    private var invalidatedAt: TimeInterval = 0
    private var freshness: TimeInterval = 5
    private var enabledAt: TimeInterval = 0
    private var freshnessTimer: Timer?
    public var pollingAvailable = true
    private let configLocation: URL?
    private let applyTargets: ([Int: Int], @escaping (Bool) -> Void) -> Void
    private let restoreAutomatic: () -> Void
    private let runningApps: () -> Set<String>
    private let usageValues: () -> [FanCurveUsageSource: Double]
    private let now: () -> TimeInterval

    internal init(configURL: URL? = nil,
                  applyTargets: @escaping ([Int: Int], @escaping (Bool) -> Void) -> Void = { FanController.shared.setFanSpeeds($0, completion: $1) },
                  restoreAutomatic: @escaping () -> Void = { FanController.shared.resetFanControl() },
                  runningApps: @escaping () -> Set<String> = { FanCurveController.runningApps() },
                  usageValues: @escaping () -> [FanCurveUsageSource: Double] = { FanCurveUsageReadings.shared.values() },
                  now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configLocation = configURL
        self.applyTargets = applyTargets
        self.restoreAutomatic = restoreAutomatic
        self.runningApps = runningApps
        self.usageValues = usageValues
        self.now = now
    }

    deinit { self.freshnessTimer?.invalidate() }

    public private(set) var profileNames: [String] = []
    public private(set) var activeProfileName: String? = nil

    public var configURL: URL {
        if let configLocation { return configLocation }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Stats").appendingPathComponent("fan-curve.json")
    }

    public func setEnabled(_ value: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.setEnabled(value) }
            return
        }
        guard self.enabled != value else { return }
        self.enabled = value
        self.generation += 1
        self.pending = []
        self.lastTargets = [:]
        self.lastApplied = [:]
        self.freshnessTimer?.invalidate()
        self.freshnessTimer = nil
        if value {
            self.enabledAt = self.now()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.checkFreshness()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.freshnessTimer = timer
        }
    }

    internal func checkFreshness() {
        if self.enabled && self.now() - max(self.sampledAt, self.enabledAt) > self.freshness {
            self.failSafe()
        }
    }

    /// Clear applied targets so the next tick rewrites the fans (used after wake
    /// or when switching profiles).
    public func reapply() {
        self.generation += 1
        self.pending = []
        self.lastTargets = [:]
        self.evaluate()
    }

    public func invalidateSamples() {
        self.invalidatedAt = self.now()
        self.sampledAt = 0
    }

    public func update(_ sensors: [Sensor_p], invalidTemperatures: Set<String>, sampledAt: TimeInterval, freshness: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sampledAt >= self.invalidatedAt else { return }
        self.sensors = sensors
        self.invalidTemperatures = invalidTemperatures
        self.sampledAt = sampledAt
        self.freshness = freshness
        self.evaluate()
    }

    private func failSafe() {
        self.setEnabled(false)
        self.resetAutomatic()
        NotificationCenter.default.post(name: Notification.Name("SensorsFanControlUnavailable"), object: nil)
    }

    private func evaluate() {
        guard self.enabled else { return }
        // Startup/wake must wait for a new sample rather than use cached data.
        guard self.sampledAt > 0 else { return }
        guard self.pollingAvailable, self.now() - self.sampledAt <= self.freshness else {
            self.failSafe()
            return
        }

        let config: FanCurveConfig?
        if let data = try? Data(contentsOf: self.configURL) {
            config = FanCurveConfig.parse(data)
        } else {
            config = nil
        }

        guard let config, let profile = config.active,
              !profile.temperatureRules.isEmpty || !profile.usageRules.isEmpty else {
            // Missing or invalid config: stop custom control and restore automatic.
            self.failSafe()
            self.publish(profileNames: [], active: nil)
            return
        }

        var keys: [String: Double] = [:]
        var names: [String: Double] = [:]
        sensors.forEach { s in
            guard s.type == .temperature, !self.invalidTemperatures.contains(s.key),
                  s.value.isFinite, (10...120).contains(s.value) else { return }
            keys[s.key.lowercased()] = s.value
            names[s.name.lowercased()] = s.value
        }

        // Every configured temperature rule must be healthy; an app override
        // must not hide a failed thermal sensor.
        guard profile.temperatureRules.allSatisfy({ FanCurveMath.temperature(for: $0, keys: keys, names: names) != nil }) else {
            self.failSafe()
            return
        }

        // A missing or stale usage source must not be masked by another rule.
        let usages = self.usageValues()
        guard profile.usageRules.allSatisfy({ rule in
            guard let value = usages[rule.source] else { return false }
            return value.isFinite && (0...100).contains(value)
        }) else {
            self.failSafe()
            return
        }

        let effective = FanCurveMath.combinedTargetSpeed(
            temperatureRules: profile.temperatureRules,
            appRules: profile.appRules,
            keys: keys,
            names: names,
            runningApps: self.runningApps(),
            usageRules: profile.usageRules,
            usages: usages
        )
        let fans = sensors.filter({ $0.type == .fan && !$0.isComputed }).compactMap({ $0 as? Fan })

        if let effective, !fans.isEmpty {
            var targets: [Int: Int] = [:]
            fans.forEach { fan in
                guard fan.minSpeed.isFinite, fan.maxSpeed.isFinite,
                      fan.minSpeed >= 0, fan.maxSpeed > 0, fan.maxSpeed <= 100_000,
                      fan.minSpeed <= fan.maxSpeed else {
                    self.failSafe()
                    return
                }
                guard self.enabled, !self.pending.contains(fan.id) else { return }
                let clamped = min(Int(fan.maxSpeed), max(Int(fan.minSpeed), effective))
                let previous = self.lastTargets[fan.id]
                let elapsed = self.now() - (self.lastApplied[fan.id] ?? 0)
                // Apply rises promptly; suppress tiny changes and rapid drops.
                if previous == nil || elapsed >= 10 ||
                    (abs(clamped - previous!) >= 100 && (clamped > previous! || elapsed >= 3)) {
                    targets[fan.id] = clamped
                }
            }
            guard self.enabled, !targets.isEmpty else { return }
            let generation = self.generation
            self.pending.formUnion(targets.keys)
            self.applyTargets(targets) { [weak self] success in
                guard let self, self.generation == generation, self.enabled else { return }
                self.pending.subtract(targets.keys)
                if success {
                    for (id, target) in targets {
                        self.lastTargets[id] = target
                        self.lastApplied[id] = self.now()
                    }
                } else {
                    self.failSafe()
                }
            }
        } else {
            self.failSafe()
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

    /// All configured rules are sampled so profile switches can reuse an
    /// already-warmed historical value and other sensor consumers can see it.
    internal func configuredTemperatureRules() -> [FanCurveRule] {
        self.currentConfig()?.profiles.flatMap({ $0.temperatureRules }) ?? []
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
        self.restoreAutomatic()
    }

    private func currentConfig() -> FanCurveConfig? {
        guard let data = try? Data(contentsOf: self.configURL) else { return nil }
        return FanCurveConfig.parse(data)
    }

    /// Lowercased bundle identifiers and display names of all regular apps.
    private static func runningApps() -> Set<String> {
        var ids: Set<String> = []
        NSWorkspace.shared.runningApplications.forEach { app in
            guard app.activationPolicy == .regular else { return }
            if let bundle = app.bundleIdentifier {
                ids.insert(bundle.lowercased())
            }
            if let name = app.localizedName {
                ids.insert(name.lowercased())
            }
        }
        return ids
    }

    private func write(_ config: FanCurveConfig) {
        let fm = FileManager.default
        let dir = self.configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = config.encoded() else { return }
        try? data.write(to: self.configURL, options: .atomic)
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
            FanCurveProfile(name: "Quiet", temperatureRules: [
                FanCurveRule(sensorName: "Average CPU", points: [
                    FanCurvePoint(temp: 60, speed: 2317),
                    FanCurvePoint(temp: 85, speed: 3500)
                ])
            ]),
            FanCurveProfile(name: "Balanced", temperatureRules: [
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
            FanCurveProfile(name: "Performance", temperatureRules: [
                FanCurveRule(sensorName: "Hottest CPU", points: [
                    FanCurvePoint(temp: 45, speed: 3500),
                    FanCurvePoint(temp: 70, speed: 7000)
                ])
            ])
        ]
    )
}

public final class FanSliderController {
    public static let shared = FanSliderController()

    private let configLocation: URL?

    internal init(configURL: URL? = nil) {
        self.configLocation = configURL
    }

    public var configURL: URL {
        if let configLocation { return configLocation }
        return FanCurveController.shared.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("fan-slider.json")
    }

    public func snappedSpeed(_ speed: Int, minimum: Int, maximum: Int) -> Int {
        guard let config = self.currentConfig() else {
            let lower = min(minimum, maximum)
            let upper = max(minimum, maximum)
            return min(upper, max(lower, speed))
        }
        return config.snappedSpeed(speed, minimum: minimum, maximum: maximum)
    }

    public func openConfig() {
        _ = self.currentConfig()
        NSWorkspace.shared.open(self.configURL)
    }

    private func currentConfig() -> FanSliderConfig? {
        let fm = FileManager.default
        let directory = self.configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: self.configURL.path) {
            self.write(Self.defaultConfig)
        }
        guard let data = try? Data(contentsOf: self.configURL) else { return nil }
        return FanSliderConfig.parse(data)
    }

    private func write(_ config: FanSliderConfig) {
        guard let data = config.encoded() else { return }
        try? data.write(to: self.configURL, options: .atomic)
    }

    private static let defaultConfig = FanSliderConfig(
        enabled: false,
        notches: [2500, 3500, 4500, 5500, 6500, 7500]
    )
}
