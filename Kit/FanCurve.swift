//
//  FanCurve.swift
//  Kit
//
//  Pure fan-curve config parsing and math. Kept in Kit so it can be unit-tested
//  independently of the Sensors module.
//

import Foundation

public struct FanCurvePoint: Codable, Equatable {
    public var temp: Double
    public var speed: Int

    public init(temp: Double, speed: Int) {
        self.temp = temp
        self.speed = speed
    }
}

public struct FanCurveRule: Codable, Equatable {
    public static let maximumAverageSeconds = 3600

    public var sensor: String?
    public var sensorName: String?
    public var averageSeconds: Int?
    public var points: [FanCurvePoint]

    public init(sensor: String? = nil, sensorName: String? = nil, averageSeconds: Int? = nil, points: [FanCurvePoint]) {
        self.sensor = sensor
        self.sensorName = sensorName
        self.averageSeconds = averageSeconds
        self.points = points
    }

    /// Stable key used by the Sensors module for a configured rolling average.
    /// Rules without `averageSeconds` continue to resolve their live source.
    public var historicalSensorKey: String? {
        guard let seconds = self.averageSeconds else { return nil }
        if let sensor = self.sensor {
            return "historical-average:\(seconds):key:\(sensor.lowercased())"
        }
        if let name = self.sensorName {
            return "historical-average:\(seconds):name:\(name.lowercased())"
        }
        return nil
    }
}

/// Usage values are percentages (0...100), unlike the 0...1 fractions
/// reported by the CPU, GPU, and RAM readers.
public struct FanCurveUsagePoint: Codable, Equatable {
    public var usage: Double
    public var speed: Int

    public init(usage: Double, speed: Int) {
        self.usage = usage
        self.speed = speed
    }
}

public enum FanCurveUsageSource: String, Codable, CaseIterable {
    case cpu
    case gpu
    case ram
}

public struct FanCurveUsageRule: Codable, Equatable {
    public var source: FanCurveUsageSource
    public var points: [FanCurveUsagePoint]

    public init(source: FanCurveUsageSource, points: [FanCurveUsagePoint]) {
        self.source = source
        self.points = points
    }
}

/// Latest live usage readings, shared across modules without making Sensors
/// depend on the CPU, GPU, or RAM frameworks. Cached DB values are not used.
public final class FanCurveUsageReadings {
    public static let shared = FanCurveUsageReadings()

    private struct Reading {
        let percentage: Double
        let sampledAt: TimeInterval
        let freshness: TimeInterval
    }

    private let lock = NSLock()
    private var readings: [FanCurveUsageSource: Reading] = [:]

    public init() {}

    public func update(_ source: FanCurveUsageSource, fraction: Double,
                       sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
                       freshness: TimeInterval) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard fraction.isFinite, (0...1).contains(fraction), sampledAt.isFinite,
              freshness.isFinite, freshness > 0 else {
            self.readings.removeValue(forKey: source)
            return
        }
        self.readings[source] = Reading(percentage: fraction * 100, sampledAt: sampledAt, freshness: freshness)
    }

    public func values(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [FanCurveUsageSource: Double] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.readings.compactMapValues { reading in
            guard time >= reading.sampledAt, time - reading.sampledAt <= reading.freshness else { return nil }
            return reading.percentage
        }
    }
}

public struct FanCurveProfile: Codable, Equatable {
    public var name: String
    public var temperatureRules: [FanCurveRule]
    public var usageRules: [FanCurveUsageRule]
    public var appRules: [FanCurveAppRule]

    public init(name: String, temperatureRules: [FanCurveRule], usageRules: [FanCurveUsageRule] = [], appRules: [FanCurveAppRule] = []) {
        self.name = name
        self.temperatureRules = temperatureRules
        self.usageRules = usageRules
        self.appRules = appRules
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case temperatureRules
        case usageRules
        case appRules
        // Legacy name used before temperature and app rules were profile-scoped.
        case rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.temperatureRules = try container.decodeIfPresent([FanCurveRule].self, forKey: .temperatureRules)
            ?? container.decodeIfPresent([FanCurveRule].self, forKey: .rules)
            ?? []
        self.usageRules = try container.decodeIfPresent([FanCurveUsageRule].self, forKey: .usageRules) ?? []
        self.appRules = try container.decodeIfPresent([FanCurveAppRule].self, forKey: .appRules) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.temperatureRules, forKey: .temperatureRules)
        try container.encode(self.usageRules, forKey: .usageRules)
        try container.encode(self.appRules, forKey: .appRules)
    }
}

/// A fixed fan speed applied while a given app is running. Rules belong to a
/// profile and are matched case-insensitively against an app's bundle identifier
/// or display name (for example "com.apple.xcode" or "Xcode").
public struct FanCurveAppRule: Codable, Equatable {
    public var app: String
    public var speed: Int

    public init(app: String, speed: Int) {
        self.app = app
        self.speed = speed
    }
}

public struct FanCurveConfig: Codable, Equatable {
    public var activeProfile: String?
    public var profiles: [FanCurveProfile]

    public init(activeProfile: String? = nil, profiles: [FanCurveProfile]) {
        self.activeProfile = activeProfile
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case activeProfile
        case profiles
        // Legacy global list. It is migrated into a profile while decoding and
        // deliberately omitted when the config is encoded again.
        case appSpeeds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeProfile = try container.decodeIfPresent(String.self, forKey: .activeProfile)
        self.profiles = try container.decode([FanCurveProfile].self, forKey: .profiles)

        let legacyRules = try container.decodeIfPresent([FanCurveAppRule].self, forKey: .appSpeeds) ?? []
        if !legacyRules.isEmpty, !self.profiles.isEmpty {
            // Existing Stats configs normally contain a Performance profile.
            // Fall back to the active/first profile for custom legacy configs so
            // decoding never silently drops their old global app rules.
            let index = self.profiles.firstIndex(where: {
                $0.name.compare("Performance", options: .caseInsensitive) == .orderedSame
            }) ?? self.activeProfile.flatMap({ active in
                self.profiles.firstIndex(where: { $0.name == active })
            }) ?? self.profiles.startIndex

            for rule in legacyRules where !self.profiles[index].appRules.contains(rule) {
                self.profiles[index].appRules.append(rule)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.activeProfile, forKey: .activeProfile)
        try container.encode(self.profiles, forKey: .profiles)
    }

    /// The profile to use: the one named by `activeProfile`, or the first profile
    /// in file order when `activeProfile` is missing or unknown.
    public var active: FanCurveProfile? {
        if let name = self.activeProfile {
            if let profile = self.profiles.first(where: { $0.name == name }) {
                return profile
            }
        }
        return self.profiles.first
    }

    public static func parse(_ data: Data) -> FanCurveConfig? {
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(FanCurveConfig.self, from: data),
              config.profiles.allSatisfy({ profile in
                  profile.temperatureRules.allSatisfy { rule in
                      !rule.points.isEmpty &&
                      (rule.averageSeconds.map({ (1...FanCurveRule.maximumAverageSeconds).contains($0) }) ?? true) &&
                      rule.points.allSatisfy {
                          $0.temp.isFinite && (0...150).contains($0.temp) && (0...100_000).contains($0.speed)
                      } && Set(rule.points.map { $0.temp }).count == rule.points.count
                  } && profile.usageRules.allSatisfy { rule in
                      !rule.points.isEmpty && rule.points.allSatisfy {
                          $0.usage.isFinite && (0...100).contains($0.usage) && (0...100_000).contains($0.speed)
                      } && Set(rule.points.map { $0.usage }).count == rule.points.count
                  } && profile.appRules.allSatisfy({ (0...100_000).contains($0.speed) })
              }) else { return nil }
        return config
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

public struct FanSliderConfig: Codable, Equatable {
    public var enabled: Bool
    public var notches: [Int]

    public init(enabled: Bool, notches: [Int]) {
        self.enabled = enabled
        self.notches = notches
    }

    public static func parse(_ data: Data) -> FanSliderConfig? {
        guard let config = try? JSONDecoder().decode(FanSliderConfig.self, from: data),
              config.notches.allSatisfy({ (0...100_000).contains($0) }) else { return nil }
        return config
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    /// Returns the nearest in-range notch, preferring the higher RPM on a tie.
    /// A disabled config or one without an in-range notch preserves the value.
    public func snappedSpeed(_ speed: Int, minimum: Int, maximum: Int) -> Int {
        let lower = min(minimum, maximum)
        let upper = max(minimum, maximum)
        let value = min(upper, max(lower, speed))
        guard self.enabled else { return value }

        let candidates = Set(self.notches).filter({ (lower...upper).contains($0) }).sorted()
        return candidates.min(by: { lhs, rhs in
            let leftDistance = abs(lhs - value)
            let rightDistance = abs(rhs - value)
            return leftDistance == rightDistance ? lhs > rhs : leftDistance < rightDistance
        }) ?? value
    }
}

public enum FanCurveMath {
    private static func interpolatedSpeed(_ points: [(Double, Int)], value: Double,
                                          validRange: ClosedRange<Double>) -> Int? {
        guard value.isFinite, points.allSatisfy({
            $0.0.isFinite && validRange.contains($0.0) && (0...100_000).contains($0.1)
        }), Set(points.map { $0.0 }).count == points.count else { return nil }
        guard points.count >= 2 else { return points.first?.1 }

        let sorted = points.sorted { $0.0 < $1.0 }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }

        for i in 0..<(sorted.count - 1) {
            let low = sorted[i]
            let high = sorted[i + 1]
            if value >= low.0 && value <= high.0 {
                let ratio = (value - low.0) / (high.0 - low.0)
                return Int((Double(low.1) + Double(high.1 - low.1) * ratio).rounded())
            }
        }
        return nil
    }

    /// Linear interpolation between sorted (temp, speed) points.
    /// Below the first point the first speed is used, above the last point the
    /// last speed is used (clamp, no extrapolation). Returns nil for < 2 points.
    public static func interpolate(_ points: [FanCurvePoint], temperature: Double) -> Int? {
        self.interpolatedSpeed(points.map { ($0.temp, $0.speed) }, value: temperature, validRange: 0...150)
    }

    /// Usage is supplied as a percentage (0...100). Endpoints are clamped.
    public static func interpolate(_ points: [FanCurveUsagePoint], usage: Double) -> Int? {
        guard (0...100).contains(usage) else { return nil }
        return self.interpolatedSpeed(points.map { ($0.usage, $0.speed) }, value: usage, validRange: 0...100)
    }

    /// Resolves the temperature for a rule against sensor lookups.
    /// `keys` and `names` are expected to be lowercased by the caller.
    public static func temperature(for rule: FanCurveRule, keys: [String: Double], names: [String: Double]) -> Double? {
        if let key = rule.historicalSensorKey {
            return keys[key.lowercased()]
        }
        if let sensor = rule.sensor?.lowercased(), let value = keys[sensor] {
            return value
        }
        if let name = rule.sensorName?.lowercased(), let value = names[name] {
            return value
        }
        return nil
    }

    /// The speed for a rule set: the maximum interpolated speed across all rules
    /// with a readable temperature. Nil when no rule can be evaluated.
    public static func targetSpeed(rules: [FanCurveRule], keys: [String: Double], names: [String: Double]) -> Int? {
        var target: Int?
        for rule in rules {
            guard let temperature = self.temperature(for: rule, keys: keys, names: names),
                  let speed = self.interpolate(rule.points, temperature: temperature) else {
                continue
            }
            if target == nil || speed > target! {
                target = speed
            }
        }
        return target
    }

    public static func usageTargetSpeed(rules: [FanCurveUsageRule], values: [FanCurveUsageSource: Double]) -> Int? {
        var target: Int?
        for rule in rules {
            guard let usage = values[rule.source], let speed = self.interpolate(rule.points, usage: usage) else { continue }
            target = max(target ?? speed, speed)
        }
        return target
    }

    /// The speed for app overrides: the maximum configured speed among entries
    /// whose `app` matches a currently running app. Nil when nothing matches.
    /// `runningApps` is expected to be lowercased by the caller.
    public static func appTargetSpeed(appRules: [FanCurveAppRule], runningApps: Set<String>) -> Int? {
        var target: Int?
        for entry in appRules where runningApps.contains(entry.app.lowercased()) {
            if target == nil || entry.speed > target! {
                target = entry.speed
            }
        }
        return target
    }

    /// The highest requested speed across temperature, usage, and app rules.
    public static func combinedTargetSpeed(temperatureRules: [FanCurveRule], appRules: [FanCurveAppRule],
                                           keys: [String: Double], names: [String: Double],
                                           runningApps: Set<String>, usageRules: [FanCurveUsageRule] = [],
                                           usages: [FanCurveUsageSource: Double] = [:]) -> Int? {
        let temperatureTarget = self.targetSpeed(rules: temperatureRules, keys: keys, names: names)
        let usageTarget = self.usageTargetSpeed(rules: usageRules, values: usages)
        let appTarget = self.appTargetSpeed(appRules: appRules, runningApps: runningApps)
        return [temperatureTarget, usageTarget, appTarget].compactMap { $0 }.max()
    }
}
