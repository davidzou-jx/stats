//
//  main.swift
//  SMC
//
//  Created by Serhiy Mytrovtsiy on 25/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

// The helper relies on a nonzero exit status when a command did not take effect.
// Stay alive during read-back; a queued closure would die with this CLI process.
private func verify(_ condition: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
        if condition() { return }
        usleep(100_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    fputs("SMC command verification failed\n", stderr)
    exit(1)
}

enum CMDType: String {
    case list
    case set
    case fan
    case fans
    case fanSpeeds
    case reset
    case help
    case unknown
    
    init(value: String) {
        switch value {
        case "list": self = .list
        case "set": self = .set
        case "fan": self = .fan
        case "fans": self = .fans
        case "fan-speeds": self = .fanSpeeds
        case "reset": self = .reset
        case "help": self = .help
        default: self = .unknown
        }
    }
}

enum FlagsType: String {
    case temperature = "T"
    case voltage = "V"
    case power = "P"
    case fans = "F"
    case all
    
    init(value: String) {
        switch value {
        case "-t": self = .temperature
        case "-v": self = .voltage
        case "-p": self = .power
        case "-f": self = .fans
        default: self = .all
        }
    }
}

func main() {
    var args = CommandLine.arguments.dropFirst()
    let cmd = CMDType(value: args.first ?? "")
    args = args.dropFirst()
    
    switch cmd {
    case .list:
        var keys = SMC.shared.getAllKeys()
        args.forEach { (arg: String) in
            let flag = FlagsType(value: arg)
            if flag != .all {
                keys = keys.filter{ $0.hasPrefix(flag.rawValue)}
            }
        }
        
        print("[INFO]: found \(keys.count) keys\n")
        
        keys.forEach { (key: String) in
            let value = SMC.shared.getValue(key)
            print("[\(key)]    ", value ?? 0)
        }
    case .set:
        guard let keyIndex = args.firstIndex(where: { $0 == "-k" }),
              let valueIndex = args.firstIndex(where: { $0 == "-v" }),
              args.indices.contains(keyIndex+1),
              args.indices.contains(valueIndex+1) else {
            return
        }
        
        let key = args[keyIndex+1]
        if key.count != 4 {
            print("[ERROR]: key must contain 4 characters!")
            return
        }
        
        guard let value = Int(args[valueIndex+1]) else {
            print("[ERROR]: wrong value passed!")
            return
        }
        
        let result = SMC.shared.write(key, value)
        if result != kIOReturnSuccess {
            print("[ERROR]: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        print("[INFO]: set \(value) on \(key)")
    case .fan:
        guard let idString = args.first, let id = Int(idString) else {
            print("[ERROR]: missing fan id")
            return
        }
        var help: Bool = true
        
        if let index = args.firstIndex(where: { $0 == "-v" }), args.indices.contains(index+1), let value = Int(args[index+1]) {
            guard (0...15).contains(id), (0...100_000).contains(value) else { exit(1) }
            SMC.shared.setFanSpeed(id, speed: value)
            #if arch(arm64)
            guard let minimum = SMC.shared.getValue("F\(id)Mn", allowZero: true), let maximum = SMC.shared.getValue("F\(id)Mx"),
                  minimum.isFinite, maximum.isFinite, minimum >= 0, maximum >= minimum else { exit(1) }
            let expected = value == 0 ? 0 : min(maximum, max(minimum, Double(value)))
            verify {
                guard let target = SMC.shared.getValue("F\(id)Tg", allowZero: true),
                      let mode = SMC.shared.getValue(SMC.shared.fanModeKey(id)) else { return false }
                return abs(target - expected) <= 1 && mode == 1
            }
            #endif
            help = false
        }
        
        if let index = args.firstIndex(where: { $0 == "-m" }), args.indices.contains(index+1),
           let raw = Int(args[index+1]), let mode = FanMode.init(rawValue: raw) {
            SMC.shared.setFanMode(id, mode: mode)
            #if arch(arm64)
            verify { SMC.shared.getValue(SMC.shared.fanModeKey(id)) == Double(raw) }
            #endif
            help = false
        }
        
        guard help else { return }
        
        print("Available Flags:")
        print("  -m    change the fan mode: 0 - automatic, 1 - manual")
        print("  -v    change the fan speed")
    case .fanSpeeds:
        let values = Array(args)
        guard !values.isEmpty, values.count % 2 == 0, values.count <= 32 else { exit(1) }
        var targets: [Int: Double] = [:]
        for i in stride(from: 0, to: values.count, by: 2) {
            guard let id = Int(values[i]), (0...15).contains(id), targets[id] == nil,
                  let speed = Int(values[i + 1]), (0...100_000).contains(speed),
                  let minimum = SMC.shared.getValue("F\(id)Mn", allowZero: true), let maximum = SMC.shared.getValue("F\(id)Mx"),
                  minimum.isFinite, maximum.isFinite, minimum >= 0,
                  maximum >= minimum, maximum > 0, maximum <= 100_000 else { exit(1) }
            targets[id] = speed == 0 ? 0 : min(maximum, max(minimum, Double(speed)))
        }
        for id in targets.keys.sorted() {
            SMC.shared.setFanSpeed(id, speed: Int(targets[id]!))
        }
        #if arch(arm64)
        verify {
            targets.allSatisfy { id, expected in
                guard let target = SMC.shared.getValue("F\(id)Tg", allowZero: true),
                      let mode = SMC.shared.getValue(SMC.shared.fanModeKey(id)) else { return false }
                return abs(target - expected) <= 1 && mode == 1
            }
        }
        #endif
    case .fans:
        guard let count = SMC.shared.getValue("FNum") else {
            print("FNum not found")
            return
        }
        print("Number of fans: \(count)\n")
        
        for i in 0..<Int(count) {
            print("\(i): \(SMC.shared.getStringValue("F\(i)ID") ?? "Fan #\(i)")")
            print("Actual speed:", SMC.shared.getValue("F\(i)Ac") ?? -1)
            print("Minimal speed:", SMC.shared.getValue("F\(i)Mn") ?? -1)
            print("Maximum speed:", SMC.shared.getValue("F\(i)Mx") ?? -1)
            print("Target speed:", SMC.shared.getValue("F\(i)Tg") ?? -1)
            print("Mode:", FanMode(rawValue: Int(SMC.shared.getValue(SMC.shared.fanModeKey(i)) ?? -1)) ?? .forced)
            
            print()
        }
    case .reset:
        #if arch(arm64)
        if SMC.shared.resetFanControl() {
            print("[reset] fan control restored to automatic")
        } else {
            print("[reset] fan control reset FAILED")
            exit(1)
        }
        verify {
            guard let count = SMC.shared.getValue("FNum"), count.isFinite, (0...16).contains(count) else { return false }
            return (0..<Int(count)).allSatisfy { SMC.shared.getValue(SMC.shared.fanModeKey($0)) == 0 }
        }
        #else
        print("[reset] not needed on Intel Macs")
        #endif
    case .help, .unknown:
        print("SMC tool\n")
        print("Usage:")
        print("  ./smc [command]\n")
        print("Available Commands:")
        print("  list     list keys and values")
        print("  set      set value to a key")
        print("  fan      set fan speed")
        print("  fans     list of fans")
        print("  reset    reset Ftst (Apple Silicon only)")
        print("  help     help menu\n")
        print("Available Flags:")
        print("  -t    list temperature sensors")
        print("  -v    list voltage sensors (list cmd) / value (set cmd)")
        print("  -p    list power sensors")
        print("  -f    list fans\n")
    }
}

main()
