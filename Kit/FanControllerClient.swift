//
//  FanControllerClient.swift
//  Kit
//
//  Adapter between Stats fan controls and the standalone FanController daemon.
//

import Cocoa
import Darwin

private let fanControllerProtocolVersion = 1
private let fanControllerSocketPath = "/var/run/fan-controller/control.sock"

private struct FanControllerTarget: Codable {
    let id: Int
    let rpm: Int
}

private struct FanControllerParameters: Codable {
    var leaseID: String?
    var targets: [FanControllerTarget]?
    var fanIDs: [Int]?

    init(leaseID: String? = nil, targets: [FanControllerTarget]? = nil, fanIDs: [Int]? = nil) {
        self.leaseID = leaseID
        self.targets = targets
        self.fanIDs = fanIDs
    }
}

private struct FanControllerRequest: Codable {
    let version: Int
    let id: String
    let method: String
    let params: FanControllerParameters?

    init(method: String, params: FanControllerParameters? = nil) {
        self.version = fanControllerProtocolVersion
        self.id = UUID().uuidString
        self.method = method
        self.params = params
    }
}

private struct FanControllerLease: Codable {
    let id: String
}

private struct FanControllerFan: Codable {
    let id: Int
    let minimumRPM: Int
    let maximumRPM: Int
    let actualRPM: Int
    let targetRPM: Int
}

private struct FanControllerStatus: Codable {
    let health: String
    let fans: [FanControllerFan]
}

private struct FanControllerResult: Codable {
    let status: FanControllerStatus?
    let lease: FanControllerLease?
}

private struct FanControllerResponseError: Codable {
    let code: String
    let message: String
}

private struct FanControllerResponse: Codable {
    let version: Int
    let id: String
    let result: FanControllerResult?
    let error: FanControllerResponseError?
}

private enum FanControllerClientError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private final class FanControllerConnection {
    private let fd: Int32
    private var readBuffer = Data()

    init() throws {
        guard fanControllerSocketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw FanControllerClientError.message("fan controller socket path is too long")
        }
        self.fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard self.fd >= 0 else { throw Self.posixError("socket") }

        do {
            var noSigPipe: Int32 = 1
            _ = setsockopt(self.fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(self.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathSize = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathSize) { destination in
                    _ = fanControllerSocketPath.withCString { source in
                        strncpy(destination, source, pathSize - 1)
                    }
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(self.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Self.posixError("connect") }

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(self.fd, &uid, &gid) == 0, uid == 0 else {
                throw FanControllerClientError.message("fan controller is not running as root")
            }
        } catch {
            Darwin.close(self.fd)
            throw error
        }
    }

    deinit { Darwin.close(self.fd) }

    func request(_ method: String, params: FanControllerParameters? = nil) throws -> FanControllerResult {
        let request = FanControllerRequest(method: method, params: params)
        var data = try JSONEncoder().encode(request)
        guard data.count <= 65_536 else { throw FanControllerClientError.message("fan controller request exceeds 64 KiB") }
        data.append(0x0a)
        try self.writeAll(data)

        let response: FanControllerResponse = try self.readMessage()
        guard response.version == fanControllerProtocolVersion, response.id == request.id else {
            throw FanControllerClientError.message("invalid fan controller response")
        }
        if let error = response.error {
            throw FanControllerClientError.message("\(error.code): \(error.message)")
        }
        guard let result = response.result else {
            throw FanControllerClientError.message("fan controller response is missing its result")
        }
        return result
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(self.fd, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.posixError("send") }
                offset += count
            }
        }
    }

    private func readMessage<T: Decodable>() throws -> T {
        while true {
            if let newline = self.readBuffer.firstIndex(of: 0x0a) {
                let line = self.readBuffer[..<newline]
                guard line.count <= 65_536 else { throw FanControllerClientError.message("fan controller response exceeds 64 KiB") }
                self.readBuffer.removeSubrange(...newline)
                return try JSONDecoder().decode(T.self, from: line)
            }
            guard self.readBuffer.count <= 65_536 else { throw FanControllerClientError.message("fan controller response exceeds 64 KiB") }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(self.fd, &chunk, chunk.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Self.posixError("receive") }
            self.readBuffer.append(contentsOf: chunk.prefix(count))
        }
    }

    private static func posixError(_ operation: String) -> FanControllerClientError {
        FanControllerClientError.message("\(operation): \(String(cString: strerror(errno)))")
    }
}

public final class FanController {
    public static let shared = FanController()

    private let queue = DispatchQueue(label: "eu.exelban.Stats.fanController")
    private var connection: FanControllerConnection?
    private var leaseID: String?
    private var renewalTimer: Timer?
    private var fanGeneration = 0

    public var isAvailable: Bool {
        guard let connection = try? FanControllerConnection(),
              let status = try? connection.request("status").status else { return false }
        return status.health == "ok"
    }

    public func openSetupGuide() {
        guard let guide = Bundle(for: FanController.self).url(forResource: "FanControllerSetup", withExtension: "md") else {
            print("fan controller: bundled setup guide is missing")
            return
        }
        NSWorkspace.shared.open(guide)
    }

    public func checkAvailability(completion: @escaping (Bool) -> Void) {
        completion(self.isAvailable)
    }

    public func setFanSpeed(_ id: Int, speed: Int, completion: @escaping (Bool) -> Void = { _ in }) {
        self.setFanSpeeds([id: speed], completion: completion)
    }

    public func setFanSpeeds(_ targets: [Int: Int], completion: @escaping (Bool) -> Void = { _ in }) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setFanSpeeds(targets, completion: completion) }
            return
        }
        self.startRenewing()
        self.fanGeneration += 1
        let generation = self.fanGeneration
        let values = targets.keys.sorted().map { FanControllerTarget(id: $0, rpm: targets[$0]!) }
        self.queue.async {
            do {
                let lease = try self.ensureLease()
                _ = try self.connection!.request("setTargets", params: FanControllerParameters(leaseID: lease, targets: values))
                DispatchQueue.main.async {
                    guard self.fanGeneration == generation else { completion(false); return }
                    completion(true)
                }
            } catch {
                self.connectionFailed(error)
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    public func setFanMode(_ id: Int, mode: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setFanMode(id, mode: mode) }
            return
        }
        if mode == FanMode.forced.rawValue {
            self.startRenewing()
            self.queue.async {
                do {
                    let lease = try self.ensureLease()
                    guard let fan = try self.connection!.request("status").status?.fans.first(where: { $0.id == id }) else {
                        throw FanControllerClientError.message("fan \(id) is unavailable")
                    }
                    let current = fan.targetRPM > 0 ? fan.targetRPM : fan.actualRPM
                    let rpm = min(fan.maximumRPM, max(fan.minimumRPM, current))
                    _ = try self.connection!.request("setTargets", params: FanControllerParameters(leaseID: lease, targets: [FanControllerTarget(id: id, rpm: rpm)]))
                } catch {
                    self.connectionFailed(error)
                }
            }
        } else if mode == FanMode.automatic.rawValue {
            self.queue.async {
                guard let lease = self.leaseID, let connection = self.connection else { return }
                do {
                    _ = try connection.request("setAutomatic", params: FanControllerParameters(leaseID: lease, fanIDs: [id]))
                } catch {
                    self.connectionFailed(error)
                }
            }
        }
    }

    public func resetFanControl(completion: @escaping (Bool) -> Void = { _ in }) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resetFanControl(completion: completion) }
            return
        }
        self.fanGeneration += 1
        self.stopRenewing()
        self.queue.async {
            guard let lease = self.leaseID, let connection = self.connection else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            do {
                _ = try connection.request("release", params: FanControllerParameters(leaseID: lease))
                self.connection = nil
                self.leaseID = nil
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.connectionFailed(error)
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    public func isActive() -> Bool {
        self.queue.sync { self.connection != nil && self.leaseID != nil }
    }

    private func ensureLease() throws -> String {
        if let leaseID, self.connection != nil { return leaseID }
        let connection = try FanControllerConnection()
        guard let lease = try connection.request("acquire").lease?.id else {
            throw FanControllerClientError.message("fan controller did not return a lease")
        }
        self.connection = connection
        self.leaseID = lease
        return lease
    }

    private func startRenewing() {
        guard self.renewalTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.renewLease() }
        RunLoop.main.add(timer, forMode: .common)
        self.renewalTimer = timer
    }

    private func stopRenewing() {
        self.renewalTimer?.invalidate()
        self.renewalTimer = nil
    }

    private func renewLease() {
        self.queue.async {
            guard let lease = self.leaseID, let connection = self.connection else { return }
            do {
                _ = try connection.request("renew", params: FanControllerParameters(leaseID: lease))
            } catch {
                self.connectionFailed(error)
            }
        }
    }

    private func connectionFailed(_ error: Error) {
        print("fan controller: \(error)")
        self.connection = nil
        self.leaseID = nil
        DispatchQueue.main.async {
            self.stopRenewing()
            NotificationCenter.default.post(name: Notification.Name("SensorsFanControlUnavailable"), object: nil)
        }
    }
}
