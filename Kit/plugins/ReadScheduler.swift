import Foundation

/// Serializes sampling and bounds bursts to one pending refresh. A request
/// arriving during a sample gets a trailing refresh so settings changes stick.
public final class ReadScheduler {
    public let queue = DispatchQueue(label: "eu.exelban.Stats.sampling", qos: .default)
    private let lock = NSLock()
    private var pending: (() -> Void)?
    private var scheduled = false

    public init() {}

    public func request(_ sample: @escaping () -> Void) {
        self.lock.lock()
        self.pending = sample
        let enqueue = !self.scheduled
        self.scheduled = true
        self.lock.unlock()
        if enqueue { self.queue.async { self.drain() } }
    }

    public func cancelPending() {
        self.lock.lock()
        self.pending = nil
        self.lock.unlock()
    }

    private func drain() {
        self.lock.lock()
        let sample = self.pending
        self.pending = nil
        if sample == nil { self.scheduled = false }
        self.lock.unlock()
        guard let sample else { return }
        sample()
        // Yield to delegate events that share the sampling queue.
        self.queue.async { self.drain() }
    }
}

/// Shares a freshly collected sample between consumers without letting either
/// consumer count the same cumulative counters twice. Failed reads aren't cached.
public final class SharedSample<Value> {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let collect: () -> Value?
    private var value: Value?
    private var collectedAt: TimeInterval = 0
    private var consumers = Set<String>()

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                collect: @escaping () -> Value?) {
        self.now = now
        self.collect = collect
    }

    public func read(consumer: String, maxAge: TimeInterval) -> Value? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value, !self.consumers.contains(consumer), self.now() - self.collectedAt <= maxAge {
            self.consumers.insert(consumer)
            return value
        }
        self.value = self.collect()
        self.collectedAt = self.now()
        self.consumers = [consumer]
        return self.value
    }
}
