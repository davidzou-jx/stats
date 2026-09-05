//
//  main.swift
//  Helper
//
//  Created by Serhiy Mytrovtsiy on 17/11/2022
//  Using Swift 5.0
//  Running on macOS 13.0
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import Security

let helper = Helper()
helper.run()

class Helper: NSObject, NSXPCListenerDelegate, HelperProtocol {
    private let listener: NSXPCListener
    private let smcQueue = DispatchQueue(label: "eu.exelban.Stats.SMC.Helper.smcQueue")
    
    private var connections = [NSXPCConnection]()
    private var shouldQuit = false
    private var shouldQuitCheckInterval = 1.0
    
    private var smc: String? = nil
    private var lastHeartbeat: TimeInterval = 0
    private var controlsFans = false
    
    override init() {
        self.listener = NSXPCListener(machServiceName: "eu.exelban.Stats.SMC.Helper.Local")
        super.init()
        self.listener.delegate = self
        self.smc = CodesignCheck.appURL.appendingPathComponent("Contents/Resources/smc").path
    }
    
    public func run() {
        let args = CommandLine.arguments.dropFirst()
        if !args.isEmpty && args.first == "uninstall" {
            NSLog("detected uninstall command")
            if let val = args.last, let pid: pid_t = Int32(val) {
                while kill(pid, 0) == 0 {
                    usleep(50000)
                }
            }
            self.uninstallHelper()
            exit(0)
        }
        
        self.listener.resume()
        while !self.shouldQuit {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: self.shouldQuitCheckInterval))
            self.smcQueue.async {
                if self.controlsFans && ProcessInfo.processInfo.systemUptime - self.lastHeartbeat > 10 {
                    self.restoreAutomatic()
                }
            }
        }
    }
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        do {
            guard let token = CodesignCheck.auditToken(for: newConnection) else {
                NSLog("unable to read audit token, dropping")
                return false
            }
            let isValid = try CodesignCheck.codeSigningMatches(auditToken: token)
            if !isValid {
                NSLog("invalid connection, dropping")
                return false
            }
        } catch {
            NSLog("error checking code signing: \(error)")
            return false
        }
        
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = {
            self.smcQueue.async {
                self.connections.removeAll { $0 === newConnection }
                if self.connections.isEmpty {
                    self.lastHeartbeat = 0
                    self.restoreAutomatic()
                }
            }
        }
        
        self.smcQueue.sync { self.connections.append(newConnection) }
        newConnection.resume()
        
        return true
    }
    
    private func uninstallHelper() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.qualityOfService = QualityOfService.userInitiated
        process.arguments = ["unload", "/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"]
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != .zero {
                NSLog("termination code: \(process.terminationStatus)")
            }
            NSLog("unloaded from launchctl")
        } catch let err {
            NSLog("launchctl unload: \(err)")
        }
        
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: "/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"))
        } catch let err {
            NSLog("plist deletion: \(err)")
        }
        NSLog("property list deleted")
        
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"))
        } catch let err {
            NSLog("helper deletion: \(err)")
        }
        NSLog("smc helper deleted")
    }
}

extension Helper {
    func heartbeat() {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        self.smcQueue.async { self.lastHeartbeat = receivedAt }
    }

    private func restoreAutomatic() {
        let result = self.callSMC(["reset"])
        self.controlsFans = result.error != nil
        if !self.controlsFans && self.connections.isEmpty {
            DispatchQueue.main.async {
                self.smcQueue.sync {
                    if self.connections.isEmpty { self.shouldQuit = true }
                }
            }
        }
    }

    func version(completion: (String) -> Void) {
        completion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }
    func setSMCPath(_ path: String) {
        self.smcQueue.sync {
            var isDirectory: ObjCBool = false
            let fm = FileManager.default
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: path),
                  (try? fm.destinationOfSymbolicLink(atPath: path)) == nil,
                  CodesignCheck.matchesSelf(path: path) else {
                NSLog("rejected smc path: \(path)")
                return
            }
            self.smc = path
        }
    }
    
    func setFanMode(id: Int, mode: Int, completion: (String?) -> Void) {
        self.smcQueue.sync {
            guard (0...1).contains(mode), (0...15).contains(id) else { completion(nil); return }
            if mode == 1 {
                self.controlsFans = true
                self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            }
            let result = self.callSMC(["fan", "\(id)", "-m", "\(mode)"])
            
            if let error = result.error, !error.isEmpty {
                NSLog("error set fan mode: \(error)")
                completion(nil)
                return
            }
            
            completion(result.output)
        }
    }
    
    func setFanSpeed(id: Int, value: Int, completion: (String?) -> Void) {
        self.smcQueue.sync {
            guard (0...100_000).contains(value), (0...15).contains(id) else { completion(nil); return }
            self.controlsFans = true
            self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
            let result = self.callSMC(["fan", "\(id)", "-v", "\(value)"])
            
            if let error = result.error, !error.isEmpty {
                NSLog("error set fan speed: \(error)")
                completion(nil)
                return
            }
            
            completion(result.output)
        }
    }

    func setFanSpeeds(ids: [Int], values: [Int], completion: (String?) -> Void) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        self.smcQueue.sync {
            guard !ids.isEmpty, ids.count == values.count, Set(ids).count == ids.count,
                  ids.allSatisfy({ (0...15).contains($0) }),
                  values.allSatisfy({ (0...100_000).contains($0) }),
                  ProcessInfo.processInfo.systemUptime - receivedAt < 10 else { completion(nil); return }
            self.controlsFans = true
            self.lastHeartbeat = receivedAt
            let arguments = ["fan-speeds"] + zip(ids, values).flatMap { [String($0), String($1)] }
            let result = self.callSMC(arguments)
            if let error = result.error {
                NSLog("error set fan speeds: \(error)")
                self.lastHeartbeat = 0
                self.restoreAutomatic()
                completion(nil)
            } else {
                completion(result.output)
            }
        }
    }
    
    func resetFanControl(completion: (String?) -> Void) {
        self.smcQueue.sync {
            let result = self.callSMC(["reset"])
            self.controlsFans = result.error != nil
            if self.controlsFans { self.lastHeartbeat = 0 }
            if let error = result.error, !error.isEmpty {
                NSLog("error reset fan control: \(error)")
                completion(nil)
                return
            }
            completion(result.output)
        }
    }
    
    public func callSMC(_ arguments: [String]) -> (output: String?, error: String?) {
        guard let smc = self.smc else {
            return (nil, "missing smc tool")
        }
        guard CodesignCheck.matchesSelf(path: smc) else {
            return (nil, "smc tool failed signature validation")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: smc)
        task.arguments = arguments
        
        // The CLI reports success through its exit status. Avoid pipe-buffer
        // deadlocks and cap the time a hardware command can occupy this queue.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.standardError
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        
        do {
            try task.run()
        } catch let err {
            return (nil, "runSMC: \(err.localizedDescription)")
        }
        
        if finished.wait(timeout: .now() + 5) == .timedOut {
            task.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            return (nil, "SMC command timed out")
        }
        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            return (nil, "SMC command failed: \(task.terminationStatus)")
        }
        return ("", nil)
    }
    
    func uninstall() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper")
        process.qualityOfService = QualityOfService.userInitiated
        process.arguments = ["uninstall", String(getpid())]
        do {
            try process.run()
        } catch let err {
            NSLog("uninstall: \(err)")
        }
        exit(0)
    }
}

// https://github.com/duanefields/VirtualKVM/blob/master/VirtualKVM/CodesignCheck.swift
enum CodesignCheckError: Error {
    case message(String)
}

struct CodesignCheck {
    static var appURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    public static func auditToken(for connection: NSXPCConnection) -> audit_token_t? {
        let raw = connection.value(forKey: "auditToken")
        var token = audit_token_t()
        if let value = raw as? NSValue {
            withUnsafeMutableBytes(of: &token) { value.getValue($0.baseAddress!, size: $0.count) }
            return token
        }
        if let data = raw as? Data, data.count == MemoryLayout<audit_token_t>.size {
            _ = withUnsafeMutableBytes(of: &token) { data.copyBytes(to: $0) }
            return token
        }
        return nil
    }
    
    public static func codeSigningMatches(auditToken token: audit_token_t) throws -> Bool {
        guard let client = try self.secStaticCode(forAuditToken: token),
              let info = try self.secCodeInfo(forStaticCode: client),
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL else { return false }
        let expected = self.appURL.appendingPathComponent("Contents/MacOS/Stats").resolvingSymlinksInPath()
        guard executable.resolvingSymlinksInPath() == expected else { return false }
        var diskCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(expected as CFURL, [], &diskCode) == errSecSuccess,
              let diskCode, let diskInfo = try self.secCodeInfo(forStaticCode: diskCode),
              let runningHash = info[kSecCodeInfoUnique as String] as? Data,
              let diskHash = diskInfo[kSecCodeInfoUnique as String] as? Data else { return false }
        return runningHash == diskHash
    }
    
    public static func matchesSelf(path: String) -> Bool {
        let expected = self.appURL.appendingPathComponent("Contents/Resources/smc")
        guard URL(fileURLWithPath: path).standardizedFileURL == expected.standardizedFileURL,
              expected.resolvingSymlinksInPath() == expected.standardizedFileURL else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }
        do {
            let selfCerts = try self.codeSigningCertificatesForSelf()
            let fileCerts = try self.codeSigningCertificates(forStaticCode: code)
            if !selfCerts.isEmpty {
                return selfCerts == fileCerts
            }
            // Ad-hoc builds (no certificate chain) are the norm for this fork.
            // Command-line tools don't carry an embedded Info.plist, so their
            // identifier is unreliable; accept the bundled smc tool when it is
            // validly signed and located inside this app bundle.
            let appPath = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            guard path == appPath + "/Contents/Resources/smc" else {
                return false
            }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckNestedCode), nil) == errSecSuccess
        } catch {
            return false
        }
    }
    
    private static func codeSigningCertificatesForSelf() throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCodeSelf() else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }
    
    private static func codeSigningCertificates(forAuditToken token: audit_token_t) throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCode(forAuditToken: token) else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }
    
    private static func executeSecFunction(_ secFunction: () -> (OSStatus) ) throws {
        let osStatus = secFunction()
        guard osStatus == errSecSuccess else {
            throw CodesignCheckError.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
        }
    }
    
    private static func secStaticCodeSelf() throws -> SecStaticCode? {
        var secCodeSelf: SecCode?
        try executeSecFunction { SecCodeCopySelf(SecCSFlags(rawValue: 0), &secCodeSelf) }
        guard let secCode = secCodeSelf else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopySelf")
        }
        return try secStaticCode(forSecCode: secCode)
    }
    
    private static func secStaticCode(forAuditToken token: audit_token_t) throws -> SecStaticCode? {
        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        var secCodeToken: SecCode?
        try executeSecFunction { SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &secCodeToken) }
        guard let secCode = secCodeToken else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopyGuestWithAttributes")
        }
        return try secStaticCode(forSecCode: secCode)
    }
    
    private static func secStaticCode(forSecCode secCode: SecCode) throws -> SecStaticCode? {
        var secStaticCodeCopy: SecStaticCode?
        try executeSecFunction { SecCodeCopyStaticCode(secCode, [], &secStaticCodeCopy) }
        guard let secStaticCode = secStaticCodeCopy else {
            throw CodesignCheckError.message("SecStaticCode returned empty from SecCodeCopyStaticCode")
        }
        return secStaticCode
    }
    
    private static func isValid(secStaticCode: SecStaticCode) throws {
        try executeSecFunction { SecStaticCodeCheckValidity(secStaticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckNestedCode), nil) }
    }
    
    private static func secCodeInfo(forStaticCode secStaticCode: SecStaticCode) throws -> [String: Any]? {
        try isValid(secStaticCode: secStaticCode)
        var secCodeInfoCFDict: CFDictionary?
        try executeSecFunction { SecCodeCopySigningInformation(secStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &secCodeInfoCFDict) }
        guard let secCodeInfo = secCodeInfoCFDict as? [String: Any] else {
            throw CodesignCheckError.message("CFDictionary returned empty from SecCodeCopySigningInformation")
        }
        return secCodeInfo
    }
    
    private static func codeSigningCertificates(forStaticCode secStaticCode: SecStaticCode) throws -> [SecCertificate] {
        guard
            let secCodeInfo = try secCodeInfo(forStaticCode: secStaticCode),
            let secCertificates = secCodeInfo[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return [] }
        return secCertificates
    }
}
