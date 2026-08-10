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
    public var sensor: String?
    public var sensorName: String?
    public var points: [FanCurvePoint]

    public init(sensor: String? = nil, sensorName: String? = nil, points: [FanCurvePoint]) {
        self.sensor = sensor
        self.sensorName = sensorName
        self.points = points
    }
}

public struct FanCurveProfile: Codable, Equatable {
    public var name: String
    public var rules: [FanCurveRule]

    public init(name: String, rules: [FanCurveRule]) {
        self.name = name
        self.rules = rules
    }
}

public struct FanCurveConfig: Codable, Equatable {
    public var activeProfile: String?
    public var profiles: [FanCurveProfile]

    public init(activeProfile: String? = nil, profiles: [FanCurveProfile]) {
        self.activeProfile = activeProfile
        self.profiles = profiles
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
        return try? decoder.decode(FanCurveConfig.self, from: data)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

public enum FanCurveMath {
    /// Linear interpolation between sorted (temp, speed) points.
    /// Below the first point the first speed is used, above the last point the
    /// last speed is used (clamp, no extrapolation). Returns nil for < 2 points.
    public static func interpolate(_ points: [FanCurvePoint], temperature: Double) -> Int? {
        guard points.count >= 2 else {
            return points.first.map { $0.speed }
        }

        let sorted = points.sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return nil }

        if temperature <= first.temp {
            return first.speed
        }
        if temperature >= last.temp {
            return last.speed
        }

        for i in 0..<(sorted.count - 1) {
            let p0 = sorted[i]
            let p1 = sorted[i + 1]
            if temperature >= p0.temp && temperature <= p1.temp {
                let ratio = (temperature - p0.temp) / (p1.temp - p0.temp)
                let speed = Double(p0.speed) + Double(p1.speed - p0.speed) * ratio
                return Int(speed.rounded())
            }
        }

        return nil
    }

    /// Resolves the temperature for a rule against sensor lookups.
    /// `keys` and `names` are expected to be lowercased by the caller.
    public static func temperature(for rule: FanCurveRule, keys: [String: Double], names: [String: Double]) -> Double? {
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
}
