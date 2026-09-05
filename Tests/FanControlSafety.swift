// Standalone regression runner: links Debug Sensors/Kit frameworks and injects
// hardware commands. It never launches Stats or contacts the privileged helper.
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
        let profile = FanCurveProfile(name: "Test", rules: [FanCurveRule(sensor: "cpu", points: [
            FanCurvePoint(temp: 50, speed: 2000), FanCurvePoint(temp: 90, speed: 6000)
        ])])
        let config = FanCurveConfig(profiles: [profile], appSpeeds: [FanCurveAppSpeed(app: "Finder", speed: 2000)])
        try config.encoded()!.write(to: url)

        var time: TimeInterval = 100
        var writes: [[Int: Int]] = []
        var resets = 0
        var replies: [(Bool) -> Void] = []
        var immediate = true
        let controller = FanCurveController(configURL: url, applyTargets: { targets, reply in
            writes.append(targets)
            if immediate { reply(true) } else { replies.append(reply) }
        }, restoreAutomatic: { resets += 1 }, now: { time })
        var cpu = Sensor(key: "cpu", name: "CPU", group: .CPU, type: .temperature, platforms: [])
        let fans: [Sensor_p] = [
            Fan(id: 0, key: "F0Ac", name: "Left", minSpeed: 2500, maxSpeed: 5500, value: 2500, mode: .automatic),
            Fan(id: 1, key: "F1Ac", name: "Right", minSpeed: 2300, maxSpeed: 5000, value: 2300, mode: .automatic)
        ]
        func sample(_ temperature: Double, invalid: Set<String> = [], age: TimeInterval = 0) {
            cpu.value = temperature
            controller.update([cpu] + fans, invalidTemperatures: invalid, sampledAt: time - age, freshness: 5)
        }

        controller.setEnabled(true)
        sample(50)
        precondition(writes.last == [0: 2500, 1: 2300], "both fans must be clamped and applied together")
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
        precondition(FanCurveMath.interpolate(profile.rules[0].points, temperature: .nan) == nil)
        precondition(FanCurveMath.interpolate([FanCurvePoint(temp: 50, speed: 2000), FanCurvePoint(temp: 50, speed: 3000)], temperature: 50) == nil)
        let invalidConfig = FanCurveConfig(profiles: [FanCurveProfile(name: "Bad", rules: [FanCurveRule(sensor: "cpu", points: extremes)])])
        precondition(FanCurveConfig.parse(invalidConfig.encoded()!) == nil)
        precondition(FanCurveConfig.parse(Data("{broken".utf8)) == nil)

        try Data("{broken".utf8).write(to: url)
        controller.setEnabled(true)
        sample(70)
        precondition(resets == 6, "invalid configuration must restore automatic")
        print("Fan-control safety regressions passed (batching, limits, hysteresis, stale/failed sensors, stopped polling, failed writes, obsolete replies, wake samples, invalid numbers/config).")
    }
}
