import Foundation
import Darwin

public struct CommandResult {
    public var output = Data()
    public var error = Data()
    public var exitCode: Int32 = -1
    public var failure: String? = nil
    public var succeeded: Bool { failure == nil && exitCode == 0 }
}

/// Runs a finite command off the UI thread. Both pipes are drained together;
/// even a child that ignores termination or leaves a pipe open has a deadline.
public func runCommand(path: String, arguments: [String] = [], environment: [String: String]? = nil,
                       timeout: TimeInterval = 30, maxOutputBytes: Int = 16 * 1024 * 1024,
                       cancelled: () -> Bool = { false }) -> CommandResult {
    var result = CommandResult()
    guard timeout.isFinite, timeout > 0, maxOutputBytes > 0 else {
        result.failure = "Invalid command limits"
        return result
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.environment = environment
    task.standardInput = FileHandle.nullDevice
    let output = Pipe(), errors = Pipe()
    task.standardOutput = output
    task.standardError = errors
    defer {
        output.fileHandleForReading.closeFile()
        errors.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        errors.fileHandleForWriting.closeFile()
    }
    if cancelled() {
        result.failure = "Command cancelled"
        return result
    }
    do { try task.run() } catch {
        result.failure = error.localizedDescription
        return result
    }
    output.fileHandleForWriting.closeFile()
    errors.fileHandleForWriting.closeFile()

    var descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
    for descriptor in descriptors {
        let flags = fcntl(descriptor, F_GETFL)
        if flags == -1 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == -1 {
            result.failure = "Cannot configure command pipe"
        }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while result.failure == nil {
        if cancelled() { result.failure = "Command cancelled"; break }
        if ProcessInfo.processInfo.systemUptime >= deadline { result.failure = "Command timed out"; break }
        if descriptors.allSatisfy({ $0 == -1 }) && !task.isRunning { break }

        var polls = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
        let ready = poll(&polls, nfds_t(polls.count), 20)
        if ready < 0 {
            if errno == EINTR { continue }
            result.failure = "Cannot poll command pipes"
            break
        }
        for i in polls.indices where polls[i].revents != 0 && descriptors[i] != -1 {
            let count = Darwin.read(descriptors[i], &buffer, buffer.count)
            if count > 0 {
                guard count <= maxOutputBytes - result.output.count - result.error.count else {
                    result.failure = "Command output exceeded limit"
                    break
                }
                if i == 0 { result.output.append(contentsOf: buffer.prefix(count)) }
                else { result.error.append(contentsOf: buffer.prefix(count)) }
            } else if count == 0 {
                descriptors[i] = -1
            } else if errno != EAGAIN && errno != EINTR {
                result.failure = "Cannot read command pipe"
                break
            }
        }
    }
    if task.isRunning {
        task.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.2
        while task.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
        if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
        // Process reaps the child asynchronously. Never wait indefinitely here.
    } else {
        result.exitCode = task.terminationStatus
    }
    return result
}
