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
            { "name": "Quiet", "rules": [] },
            { "name": "Performance", "rules": [ { "sensor": "Tp04", "points": [ { "temp": 50, "speed": 2400 } ] } ] }
          ]
        }
        """.data(using: .utf8)!

        let config = FanCurveConfig.parse(json)
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.active?.name, "Performance")
        XCTAssertEqual(config?.profiles.count, 2)
        XCTAssertEqual(config?.profiles.first?.name, "Quiet")
    }

    func testActiveProfileDefaultsToFirst() throws {
        let json = """
        {
          "profiles": [
            { "name": "Quiet", "rules": [] },
            { "name": "Performance", "rules": [] }
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
            { "name": "Quiet", "rules": [] }
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
}
