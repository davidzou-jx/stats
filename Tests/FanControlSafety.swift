// Standalone regression runner: links Debug Sensors/Kit frameworks and injects
// hardware commands. It never launches Stats or contacts FanController.
import Foundation
import Kit
@testable import Sensors

@main
struct FanControlSafetyTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fan-curve.json")
        let temperatureRules = [FanCurveRule(sensor: "cpu", points: [
            FanCurvePoint(temp: 50, speed: 2000), FanCurvePoint(temp: 90, speed: 6000)
        ])]
        let profile = FanCurveProfile(name: "Test", temperatureRules: temperatureRules, appRules: [
            FanCurveAppRule(app: "Finder", speed: 2000)
        ])
        let performance = FanCurveProfile(name: "Performance", temperatureRules: temperatureRules, appRules: [
            FanCurveAppRule(app: "Finder", speed: 5000)
        ])
        let config = FanCurveConfig(activeProfile: "Test", profiles: [profile, performance])
        try config.encoded()!.write(to: url)

        var time: TimeInterval = 100
        var writes: [[Int: Int]] = []
        var resets = 0
        var replies: [(Bool) -> Void] = []
        var immediate = true
        let controller = FanCurveController(configURL: url, applyTargets: { targets, reply in
            writes.append(targets)
            if immediate { reply(true) } else { replies.append(reply) }
        }, restoreAutomatic: { resets += 1 }, runningApps: { ["finder"] }, now: { time })
        var cpu = Sensor(key: "cpu", name: "CPU", group: .CPU, type: .temperature, platforms: [])
        let fans: [Sensor_p] = [
            Fan(id: 0, key: "F0Ac", name: "Left", minSpeed: 2500, maxSpeed: 5500, value: 2500, mode: .automatic),
            Fan(id: 1, key: "F1Ac", name: "Right", minSpeed: 2300, maxSpeed: 5000, value: 2300, mode: .automatic)
        ]

        let averageRule = FanCurveRule(sensor: "cpu", averageSeconds: 10, points: temperatureRules[0].points)
        let shortAverageRule = FanCurveRule(sensor: "cpu", averageSeconds: 3, points: temperatureRules[0].points)
        let averageKey = averageRule.historicalSensorKey!
        let shortAverageKey = shortAverageRule.historicalSensorKey!
        let averages = HistoricalTemperatureAverages()
        func rolling(_ temperature: Double, at timestamp: TimeInterval, rules: [FanCurveRule] = [averageRule], invalid: Set<String> = []) -> (sensors: [Sensor], invalid: Set<String>) {
            cpu.value = temperature
            return averages.update(sensors: [cpu], rules: rules, invalidTemperatures: invalid, sampledAt: timestamp)
        }

        var historical = rolling(40, at: 100)
        precondition(historical.sensors.first?.value == 40, "historical averages must publish during warm-up")
        historical = rolling(60, at: 105)
        precondition(historical.sensors.first?.value == 50)
        historical = rolling(80, at: 110)
        precondition(historical.sensors.first?.value == 60, "samples exactly on the window boundary must remain included")
        historical = rolling(70, at: 111)
        precondition(historical.sensors.first?.value == 70, "samples older than the window must be evicted")
        precondition(historical.sensors.first?.key == averageKey)
        precondition(historical.sensors.first?.name == "CPU (10s average)")
        precondition(historical.sensors.first?.type == .temperature && historical.sensors.first?.isComputed == true)

        historical = rolling(0, at: 112, invalid: ["cpu"])
        precondition(historical.invalid == [averageKey], "invalid sources must invalidate their historical sensor")
        historical = rolling(90, at: 113)
        precondition(historical.sensors.first?.value == 90, "a valid sample after a failure must start fresh history")

        averages.reset()
        _ = rolling(40, at: 100, rules: [averageRule, shortAverageRule, averageRule])
        historical = rolling(60, at: 105, rules: [averageRule, shortAverageRule, averageRule])
        precondition(historical.sensors.count == 2, "duplicate configured requests must be deduplicated")
        precondition(historical.sensors.first(where: { $0.key == averageKey })?.value == 50)
        precondition(historical.sensors.first(where: { $0.key == shortAverageKey })?.value == 60, "different windows must retain independent histories")

        func sample(_ temperature: Double, invalid: Set<String> = [], age: TimeInterval = 0) {
            cpu.value = temperature
            controller.update([cpu] + fans, invalidTemperatures: invalid, sampledAt: time - age, freshness: 5)
        }

        controller.setEnabled(true)
        sample(50)
        precondition(writes.last == [0: 2500, 1: 2300], "inactive profile app rules must not apply")
        controller.selectProfile("Performance")
        precondition(writes.last == [0: 5000, 1: 5000], "the active profile's app rule must beat its temperature rule")
        controller.selectProfile("Test")
        precondition(writes.last == [0: 2500, 1: 2300], "profile selection must switch app rules together with temperature rules")
        sample(70)
        precondition(writes.last == [0: 4000, 1: 4000], "temperature rises must apply immediately")
        let stableCount = writes.count
        time += 1
        sample(70.2)
        precondition(writes.count == stableCount, "small temperature jitter must not change targets")
        sample(60)
        precondition(writes.count == stableCount, "decreases must wait for the settling interval")
        time += 3
        sample(60)
        precondition(writes.last == [0: 3000, 1: 3000])
        sample(90)
        precondition(writes.last == [0: 5500, 1: 5000], "maximum limits must be enforced")

        sample(50, invalid: ["cpu"])
        precondition(resets == 1, "failed temperature reads must restore automatic")
        let disabledCount = writes.count
        sample(90)
        precondition(writes.count == disabledCount, "a safety reset must disable custom control")

        controller.setEnabled(true)
        sample(70, age: 6)
        precondition(resets == 2, "stale samples must restore automatic")
        controller.setEnabled(true)
        sample(70)
        time += 6
        controller.checkFreshness()
        precondition(resets == 3, "stopped sampling must reset without another sample arriving")

        controller.setEnabled(true)
        controller.pollingAvailable = false
        sample(70)
        precondition(resets == 4, "paused polling must not permit custom control")
        controller.pollingAvailable = true

        immediate = false
        controller.setEnabled(true)
        sample(70)
        replies.removeFirst()(false)
        precondition(resets == 5, "failed hardware writes must restore automatic")
        controller.setEnabled(true)
        sample(70)
        precondition(!replies.isEmpty, "a failed target must be retried when control is re-enabled")
        controller.setEnabled(false)
        replies.removeFirst()(false)
        precondition(resets == 5, "obsolete completions must not affect a newer mode")

        controller.setEnabled(true)
        sample(70)
        controller.reapply()
        let obsolete = replies.removeFirst()
        obsolete(false)
        precondition(resets == 5, "profile reapplication must invalidate outstanding acknowledgements")
        replies.removeFirst()(true)
        controller.setEnabled(false)

        controller.invalidateSamples()
        let oldCount = writes.count
        controller.setEnabled(true)
        sample(90, age: 1)
        precondition(writes.count == oldCount, "pre-sleep samples must not be reused")
        controller.setEnabled(false)

        let extremes = [FanCurvePoint(temp: 50, speed: Int.min), FanCurvePoint(temp: 90, speed: Int.max)]
        precondition(FanCurveMath.interpolate(extremes, temperature: 70) == nil)
        precondition(FanCurveMath.interpolate(profile.temperatureRules[0].points, temperature: .nan) == nil)
        precondition(FanCurveMath.interpolate([FanCurvePoint(temp: 50, speed: 2000), FanCurvePoint(temp: 50, speed: 3000)], temperature: 50) == nil)
        let invalidConfig = FanCurveConfig(profiles: [FanCurveProfile(name: "Bad", temperatureRules: [FanCurveRule(sensor: "cpu", points: extremes)])])
        precondition(FanCurveConfig.parse(invalidConfig.encoded()!) == nil)
        precondition(FanCurveConfig.parse(Data("{broken".utf8)) == nil)

        // Usage rules can drive a profile without temperature rules. They also
        // fail safe when a configured source disappears, even if an app matches.
        let usageURL = directory.appendingPathComponent("usage-fan-curve.json")
        let usageRule = FanCurveUsageRule(source: .cpu, points: [
            FanCurveUsagePoint(usage: 0, speed: 2000), FanCurveUsagePoint(usage: 100, speed: 6000)
        ])
        let usageProfile = FanCurveProfile(name: "Usage", temperatureRules: [], usageRules: [usageRule], appRules: [
            FanCurveAppRule(app: "Finder", speed: 5000)
        ])
        try FanCurveConfig(profiles: [usageProfile]).encoded()!.write(to: usageURL)
        var usageValues: [FanCurveUsageSource: Double] = [:]
        var usageWrites: [[Int: Int]] = []
        var usageResets = 0
        let usageController = FanCurveController(configURL: usageURL, applyTargets: { targets, reply in
            usageWrites.append(targets)
            reply(true)
        }, restoreAutomatic: { usageResets += 1 }, runningApps: { ["finder"] },
        usageValues: { usageValues }, now: { time })
        usageController.setEnabled(true)
        usageController.update(fans, invalidTemperatures: [], sampledAt: time, freshness: 5)
        precondition(usageResets == 1 && usageWrites.isEmpty, "missing usage must restore automatic even with an app override")

        usageValues[.cpu] = 50
        usageController.setEnabled(true)
        usageController.update(fans, invalidTemperatures: [], sampledAt: time, freshness: 5)
        precondition(usageWrites.last == [0: 5000, 1: 5000], "the app rule must beat a lower usage target")
        usageValues[.cpu] = 100
        time += 1
        usageController.update(fans, invalidTemperatures: [], sampledAt: time, freshness: 5)
        precondition(usageWrites.last == [0: 5500], "usage must raise the first fan and respect its hardware limit")
        usageValues.removeAll()
        usageController.update(fans, invalidTemperatures: [], sampledAt: time, freshness: 5)
        precondition(usageResets == 2, "lost usage readings must restore automatic")

        let mixedProfile = FanCurveProfile(name: "Mixed", temperatureRules: temperatureRules, usageRules: [usageRule])
        try FanCurveConfig(profiles: [mixedProfile]).encoded()!.write(to: usageURL)
        usageController.setEnabled(true)
        usageController.update([cpu] + fans, invalidTemperatures: [], sampledAt: time, freshness: 5)
        precondition(usageResets == 3, "a temperature target must not mask missing usage")

        let sliderURL = directory.appendingPathComponent("fan-slider.json")
        let sliderController = FanSliderController(configURL: sliderURL)
        precondition(sliderController.snappedSpeed(4200, minimum: 2500, maximum: 7000) == 4200)
        precondition(FileManager.default.fileExists(atPath: sliderURL.path), "the slider config must be created beside the fan config")
        let sliderConfig = FanSliderConfig(enabled: true, notches: [3000, 4000, 5000])
        try sliderConfig.encoded()!.write(to: sliderURL)
        precondition(sliderController.snappedSpeed(4200, minimum: 2500, maximum: 7000) == 4000)

        try Data("{broken".utf8).write(to: url)
        controller.setEnabled(true)
        sample(70)
        precondition(resets == 6, "invalid configuration must restore automatic")
        print("Fan-control safety regressions passed (batching, limits, hysteresis, temperature/usage safety, stopped polling, failed writes, obsolete replies, wake samples, invalid numbers/config).")
    }
}
