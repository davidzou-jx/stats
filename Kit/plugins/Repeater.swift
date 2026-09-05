//
//  Repeater.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 27/06/2022.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

private enum RepeaterState {
    case paused
    case running
}

internal class Repeater {
    private var callback: (() -> Void)
    private var state: RepeaterState = .paused
    private let stateLock = NSLock()
    private var generation: UInt = 0
    
    private let timerQueue = DispatchQueue(label: "eu.exelban.Stats.Repeater", qos: .default)
    private lazy var timer: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: self.timerQueue)
    
    internal init(seconds: Int, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.setupTimer(seconds)
    }
    
    deinit {
        self.timer.setEventHandler {}
        self.timer.cancel()
        if self.state == .paused {
            self.timer.resume()
            self.state = .running
        }
    }
    
    private func setupTimer(_ seconds: Int) {
        let interval = max(1, seconds)
        self.timer.schedule(
            deadline: DispatchTime.now() + Double(interval),
            repeating: .seconds(interval),
            leeway: .milliseconds(200)
        )
        self.timer.setEventHandler { [weak self] in
            self?.fire()
        }
    }
    
    internal func start() {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        guard self.state == .paused else { return }
        
        self.timer.resume()
        self.state = .running
    }
    
    internal func pause() {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.generation &+= 1
        guard self.state == .running else { return }
        
        self.timer.suspend()
        self.state = .paused
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.generation &+= 1
        let generation = self.generation
        if self.state == .running {
            self.timer.suspend()
            self.state = .paused
        }
        self.setupTimer(seconds)
        if restart {
            self.timer.resume()
            self.state = .running
            self.timerQueue.async { [weak self] in self?.fire(generation: generation) }
        }
    }

    private func fire(generation: UInt? = nil) {
        self.stateLock.lock()
        let shouldFire = self.state == .running && (generation == nil || generation == self.generation)
        self.stateLock.unlock()
        if shouldFire { self.callback() }
    }
}
