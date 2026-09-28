//
//  FanCurve.swift
//  Tests
//

import XCTest
import Kit

final class FanCurveTests: XCTestCase {
    private func points(_ values: [(Double, Int)]) -> [FanCurvePoint] {
        values.map { FanCurvePoint(temp: $0.0, speed: $0.1) }
    }

    private func usagePoints(_ values: [(Double, Int)]) -> [FanCurveUsagePoint] {
        values.map { FanCurveUsagePoint(usage: $0.0, speed: $0.1) }
    }

    func testUsageInterpolationAndClamping() {
        let curve = self.usagePoints([(80, 6000), (20, 2000)])
        XCTAssertEqual(FanCurveMath.interpolate(curve, usage: 50), 4000)
        XCTAssertEqual(FanCurveMath.interpolate(curve, usage: 0), 2000)
        XCTAssertEqual(FanCurveMath.interpolate(curve, usage: 100), 6000)
        XCTAssertNil(FanCurveMath.interpolate(curve, usage: .nan))
        XCTAssertNil(FanCurveMath.interpolate(curve, usage: -1))
        XCTAssertNil(FanCurveMath.interpolate(self.usagePoints([(20, 2000), (20, 3000)]), usage: 20))
    }

    func testUsageRulesRoundTripBesideTemperatureRules() throws {
        let data = Data("""
        {
          "profiles": [{
            "name": "Balanced",
            "temperatureRules": [{"sensor": "cpu-temp", "points": [{"temp": 60, "speed": 3000}]}],
            "usageRules": [
              {"source": "cpu", "points": [{"usage": 20, "speed": 2000}, {"usage": 80, "speed": 6000}]},
              {"source": "gpu", "points": [{"usage": 50, "speed": 4500}]}
            ]
          }]
        }
        """.utf8)
        let config = try XCTUnwrap(FanCurveConfig.parse(data))
        XCTAssertEqual(config.active?.usageRules.map(\.source), [.cpu, .gpu])
        XCTAssertEqual(FanCurveConfig.parse(try XCTUnwrap(config.encoded())), config)
        XCTAssertEqual(FanCurveMath.combinedTargetSpeed(
            temperatureRules: config.active!.temperatureRules, appRules: [],
            keys: ["cpu-temp": 60], names: [:], runningApps: [],
            usageRules: config.active!.usageRules, usages: [.cpu: 50, .gpu: 50]
        ), 4500)
    }

    func testUsageOnlyAndHighestRuleWins() {
        let rules = [
            FanCurveUsageRule(source: .cpu, points: self.usagePoints([(0, 2000), (100, 6000)])),
            FanCurveUsageRule(source: .ram, points: self.usagePoints([(50, 5000)]))
        ]
        XCTAssertEqual(FanCurveMath.usageTargetSpeed(rules: rules, values: [.cpu: 50, .ram: 70]), 5000)
        XCTAssertEqual(FanCurveMath.combinedTargetSpeed(
            temperatureRules: [], appRules: [FanCurveAppRule(app: "Xcode", speed: 5500)],
            keys: [:], names: [:], runningApps: ["xcode"], usageRules: rules,
            usages: [.cpu: 50, .ram: 70]
        ), 5500)
    }

    func testInvalidUsageConfigIsRejected() {
        for usage in [-1.0, 101] {
            let config = FanCurveConfig(profiles: [FanCurveProfile(name: "Bad", temperatureRules: [], usageRules: [
                FanCurveUsageRule(source: .cpu, points: self.usagePoints([(usage, 3000)]))
            ])])
            XCTAssertNil(FanCurveConfig.parse(config.encoded()!))
        }
        let duplicate = FanCurveConfig(profiles: [FanCurveProfile(name: "Bad", temperatureRules: [], usageRules: [
            FanCurveUsageRule(source: .cpu, points: self.usagePoints([(20, 2000), (20, 3000)]))
        ])])
        XCTAssertNil(FanCurveConfig.parse(duplicate.encoded()!))
        XCTAssertNil(FanCurveConfig.parse(Data(#"{"profiles":[{"name":"Bad","usageRules":[{"source":"disk","points":[{"usage":50,"speed":3000}]}]}]}"#.utf8)))
    }

    func testUsageReadingsExpireAndRejectInvalidFractions() {
        let readings = FanCurveUsageReadings()
        readings.update(.cpu, fraction: 0.42, sampledAt: 100, freshness: 5)
        XCTAssertEqual(readings.values(at: 105)[.cpu], 42)
        XCTAssertNil(readings.values(at: 106)[.cpu])
        readings.update(.cpu, fraction: .nan, sampledAt: 104, freshness: 5)
        XCTAssertNil(readings.values(at: 104)[.cpu])
        readings.update(.gpu, fraction: 1.2, sampledAt: 106, freshness: 5)
        XCTAssertNil(readings.values(at: 106)[.gpu])
    }

    func testInterpolationBetweenPoints() {
        let curve = self.points([(50, 2400), (70, 4500)])
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 60), 3450)
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 50), 2400)
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 70), 4500)
    }

    func testEndpointClamping() {
        let curve = self.points([(50, 2400), (70, 4500)])
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 30), 2400)
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 95), 4500)
    }

    func testUnsortedPointsAreSorted() {
        let curve = self.points([(70, 4500), (50, 2400)])
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 60), 3450)
    }

    func testSinglePointRule() {
        let curve = self.points([(60, 3000)])
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 10), 3000)
        XCTAssertEqual(FanCurveMath.interpolate(curve, temperature: 90), 3000)
    }

    func testMaxSelectionAcrossRules() {
        let rules = [
            FanCurveRule(sensor: "Tp04", points: self.points([(50, 2400), (90, 7000)])),
            FanCurveRule(sensorName: "Average CPU", points: self.points([(50, 3500), (90, 5000)]))
        ]
        let keys = ["tp04": 70.0]
        let names = ["average cpu": 70.0]
        // 70°C: rule 1 → 4700, rule 2 → 4250 → max is 4700
        XCTAssertEqual(FanCurveMath.targetSpeed(rules: rules, keys: keys, names: names), 4700)
    }

    func testUnmatchedRulesReturnNil() {
        let rules = [FanCurveRule(sensor: "Tp99", points: self.points([(50, 2400), (90, 7000)]))]
        XCTAssertNil(FanCurveMath.targetSpeed(rules: rules, keys: ["tp04": 70.0], names: [:]))
    }

    func testCaseInsensitiveNameMatching() {
        let rule = FanCurveRule(sensorName: "Average CPU", points: self.points([(50, 2400), (90, 7000)]))
        let names = ["average cpu": 80.0]
        XCTAssertEqual(FanCurveMath.temperature(for: rule, keys: [:], names: names), 80.0)
    }

    func testConfigParsing() throws {
        let json = """
        {
          "activeProfile": "Performance",
          "profiles": [
            { "name": "Quiet", "temperatureRules": [], "appRules": [] },
            { "name": "Performance", "temperatureRules": [ { "sensor": "Tp04", "points": [ { "temp": 50, "speed": 2400 } ] } ], "appRules": [] }
          ]
        }
        """.data(using: .utf8)!

        let config = FanCurveConfig.parse(json)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.active?.name, "Performance")
        XCTAssertEqual(config?.profiles.count, 2)
        XCTAssertEqual(config?.profiles.first?.name, "Quiet")
    }

    func testHistoricalAverageConfigRoundTripAndLegacyDefault() throws {
        let json = Data("""
        {
          "profiles": [
            {
              "name": "Balanced",
              "temperatureRules": [
                { "sensorName": "Average CPU", "averageSeconds": 30, "points": [ { "temp": 50, "speed": 2400 } ] },
                { "sensor": "Tp04", "points": [ { "temp": 60, "speed": 3000 } ] }
              ]
            }
          ]
        }
        """.utf8)

        let config = try XCTUnwrap(FanCurveConfig.parse(json))
        XCTAssertEqual(config.active?.temperatureRules[0].averageSeconds, 30)
        XCTAssertNil(config.active?.temperatureRules[1].averageSeconds)
        XCTAssertEqual(FanCurveConfig.parse(try XCTUnwrap(config.encoded())), config)
    }

    func testHistoricalAverageWindowValidation() {
        func config(_ seconds: Int) -> FanCurveConfig {
            FanCurveConfig(profiles: [
                FanCurveProfile(name: "Test", temperatureRules: [
                    FanCurveRule(sensor: "cpu", averageSeconds: seconds, points: self.points([(50, 2400)]))
                ])
            ])
        }

        XCTAssertNil(FanCurveConfig.parse(config(0).encoded()!))
        XCTAssertNotNil(FanCurveConfig.parse(config(FanCurveRule.maximumAverageSeconds).encoded()!))
        XCTAssertNil(FanCurveConfig.parse(config(FanCurveRule.maximumAverageSeconds + 1).encoded()!))
    }

    func testHistoricalRuleResolvesOnlyItsComputedSensor() throws {
        let rule = FanCurveRule(sensor: "cpu", averageSeconds: 30, points: self.points([(50, 2400)]))
        let key = try XCTUnwrap(rule.historicalSensorKey)

        XCTAssertEqual(FanCurveMath.temperature(for: rule, keys: [key: 65, "cpu": 90], names: [:]), 65)
        XCTAssertNil(FanCurveMath.temperature(for: rule, keys: ["cpu": 90], names: [:]))
    }

    func testActiveProfileDefaultsToFirst() throws {
        let json = """
        {
          "profiles": [
            { "name": "Quiet", "temperatureRules": [], "appRules": [] },
            { "name": "Performance", "temperatureRules": [], "appRules": [] }
          ]
        }
        """.data(using: .utf8)!

        let config = FanCurveConfig.parse(json)
        XCTAssertEqual(config?.active?.name, "Quiet")
    }

    func testUnknownActiveProfileFallsBack() throws {
        let json = """
        {
          "activeProfile": "Missing",
          "profiles": [
            { "name": "Quiet", "temperatureRules": [], "appRules": [] }
          ]
        }
        """.data(using: .utf8)!

        let config = FanCurveConfig.parse(json)
        XCTAssertEqual(config?.active?.name, "Quiet")
    }

    func testInvalidConfigReturnsNil() {
        let data = "{ not json".data(using: .utf8)!
        XCTAssertNil(FanCurveConfig.parse(data))
    }

    func testUnsafeNumericValuesAreRejected() {
        let extreme = self.points([(50, Int.min), (90, Int.max)])
        XCTAssertNil(FanCurveMath.interpolate(extreme, temperature: 70))
        XCTAssertNil(FanCurveMath.interpolate(self.points([(50, 2000), (90, 6000)]), temperature: .nan))
        XCTAssertNil(FanCurveMath.interpolate(self.points([(50, 2000), (50, 3000)]), temperature: 50))
        let config = FanCurveConfig(profiles: [FanCurveProfile(name: "Invalid", temperatureRules: [FanCurveRule(sensor: "cpu", points: extreme)])])
        XCTAssertNil(FanCurveConfig.parse(config.encoded()!))
    }

    func testAppSpeedMatchingIsCaseInsensitive() {
        let appRules = [FanCurveAppRule(app: "com.apple.Xcode", speed: 4500)]
        XCTAssertEqual(FanCurveMath.appTargetSpeed(appRules: appRules, runningApps: ["com.apple.xcode"]), 4500)
        XCTAssertEqual(FanCurveMath.appTargetSpeed(appRules: appRules, runningApps: ["xcode"]), nil)
    }

    func testAppSpeedMatchesDisplayName() {
        let appRules = [
            FanCurveAppRule(app: "Xcode", speed: 4000),
            FanCurveAppRule(app: "docker", speed: 5000)
        ]
        XCTAssertEqual(FanCurveMath.appTargetSpeed(appRules: appRules, runningApps: ["xcode", "docker"]), 5000)
        XCTAssertEqual(FanCurveMath.appTargetSpeed(appRules: appRules, runningApps: ["finder"]), nil)
    }

    func testProfileScopedAppRules() throws {
        let json = """
        {
          "activeProfile": "Quiet",
          "profiles": [
            {
              "name": "Quiet",
              "temperatureRules": [],
              "appRules": []
            },
            {
              "name": "Performance",
              "temperatureRules": [],
              "appRules": [
                { "app": "com.apple.xcode", "speed": 4500 },
                { "app": "Docker", "speed": 5000 }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let config = FanCurveConfig.parse(json)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.active?.name, "Quiet")
        XCTAssertEqual(config?.active?.appRules, [])
        XCTAssertEqual(config?.profiles.last?.appRules.count, 2)
        XCTAssertEqual(config?.profiles.last?.appRules.first?.app, "com.apple.xcode")
    }

    func testMissingAppRulesDecodeAsEmpty() throws {
        let json = """
        {
          "profiles": [ { "name": "Quiet", "rules": [] } ]
        }
        """.data(using: .utf8)!

        let config = FanCurveConfig.parse(json)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.active?.temperatureRules, [])
        XCTAssertEqual(config?.active?.usageRules, [])
        XCTAssertEqual(config?.active?.appRules, [])
    }

    func testLegacyGlobalAppSpeedsMigrateToPerformance() throws {
        let json = """
        {
          "activeProfile": "Quiet",
          "appSpeeds": [
            { "app": "com.apple.xcode", "speed": 4500 }
          ],
          "profiles": [
            { "name": "Quiet", "rules": [] },
            { "name": "Performance", "rules": [] }
          ]
        }
        """.data(using: .utf8)!

        let config = try XCTUnwrap(FanCurveConfig.parse(json))
        XCTAssertEqual(config.profiles[0].appRules, [])
        XCTAssertEqual(config.profiles[1].appRules, [FanCurveAppRule(app: "com.apple.xcode", speed: 4500)])

        let encoded = try XCTUnwrap(config.encoded())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["appSpeeds"])
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertNil(profiles[0]["rules"])
        XCTAssertNotNil(profiles[0]["temperatureRules"])
        XCTAssertNotNil(profiles[0]["appRules"])
    }

    func testHighestRPMWinsAcrossTemperatureAndAppRules() {
        let temperatureRules = [FanCurveRule(sensor: "cpu", points: self.points([(50, 3000), (90, 7000)]))]
        let appRules = [
            FanCurveAppRule(app: "Xcode", speed: 6000),
            FanCurveAppRule(app: "Docker", speed: 5000)
        ]

        XCTAssertEqual(FanCurveMath.combinedTargetSpeed(
            temperatureRules: temperatureRules,
            appRules: appRules,
            keys: ["cpu": 70],
            names: [:],
            runningApps: ["xcode", "docker"]
        ), 6000, "the highest matching app rule must beat the temperature target")
        XCTAssertEqual(FanCurveMath.combinedTargetSpeed(
            temperatureRules: temperatureRules,
            appRules: appRules,
            keys: ["cpu": 80],
            names: [:],
            runningApps: ["xcode", "docker"]
        ), 6000, "the higher temperature target must win when it catches the app rule")
        XCTAssertEqual(FanCurveMath.combinedTargetSpeed(
            temperatureRules: temperatureRules,
            appRules: appRules,
            keys: ["cpu": 90],
            names: [:],
            runningApps: ["xcode", "docker"]
        ), 7000, "the temperature target must win when it is highest")
    }

    func testInvalidProfileAppRuleIsRejected() {
        let config = FanCurveConfig(profiles: [
            FanCurveProfile(name: "Invalid", temperatureRules: [], appRules: [
                FanCurveAppRule(app: "Xcode", speed: -1)
            ])
        ])
        XCTAssertNil(FanCurveConfig.parse(config.encoded()!))
    }

    func testFanSliderConfigParsing() throws {
        let data = Data("""
        {
          "enabled": true,
          "notches": [2500, 3500, 4500]
        }
        """.utf8)

        let config = try XCTUnwrap(FanSliderConfig.parse(data))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.notches, [2500, 3500, 4500])
        XCTAssertEqual(FanSliderConfig.parse(config.encoded()!), config)
        XCTAssertNil(FanSliderConfig.parse(Data(#"{"enabled":true,"notches":[-1]}"#.utf8)))
    }

    func testFanSliderSnapsToNearestInRangeNotch() {
        let config = FanSliderConfig(enabled: true, notches: [7500, 2500, 4500, 4500, 1500])
        XCTAssertEqual(config.snappedSpeed(4200, minimum: 2000, maximum: 7000), 4500)
        XCTAssertEqual(config.snappedSpeed(3500, minimum: 2000, maximum: 7000), 4500, "ties prefer the higher RPM")
        XCTAssertEqual(config.snappedSpeed(6800, minimum: 2000, maximum: 7000), 4500, "out-of-range notches are ignored")
    }

    func testDisabledOrEmptyFanSliderConfigPreservesValue() {
        XCTAssertEqual(
            FanSliderConfig(enabled: false, notches: [2500]).snappedSpeed(3200, minimum: 2000, maximum: 7000),
            3200
        )
        XCTAssertEqual(
            FanSliderConfig(enabled: true, notches: []).snappedSpeed(8000, minimum: 2000, maximum: 7000),
            7000
        )
    }
}
