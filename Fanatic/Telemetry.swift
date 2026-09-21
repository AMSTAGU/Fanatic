//
//  Telemetry.swift
//  Fan
//
//  Owns the sampling cadence. The menu bar only needs the fans, so that is all
//  that is read most of the time; the full picture is gathered only while the
//  stats panel is actually on screen.
//

import Foundation

struct Telemetry {
    var fans: [FanReading] = []
    var temperatures: [TemperatureGroup] = []
    var power: [PowerRail] = []
    var cpu = CPULoad()
    var memory = MemoryLoad()
    var network = NetworkLoad()
    /// Recent CPU busy fractions, oldest first, for the panel's sparkline.
    var cpuHistory: [Double] = []

    /// The busiest fan drives the animation: it is the one you can hear.
    var leadFan: FanReading? {
        fans.max { $0.fractionOfMaximum < $1.fractionOfMaximum }
    }

    /// Visual rate for the menu bar rotor, in turns per second.
    ///
    /// The fan's speed is raised to a power rather than mapped straight across:
    /// most of the time the fan sits in the bottom third of its range, and a
    /// linear mapping spends all its resolution there, leaving idle and working
    /// hard looking alike. The curve keeps the low end a slow drift and saves
    /// the visible speed for when the fan is genuinely spinning up.
    var rotorRevolutionsPerSecond: Double {
        guard let fan = leadFan, !fan.isStopped else { return 0 }
        let curved = pow(fan.fractionOfMaximum, Self.responseCurve)
        return max(Self.slowestRate, Self.fastestRate * curved)
    }

    /// Floor, so a fan that is turning slowly never looks stopped.
    private static let slowestRate = 0.25
    private static let responseCurve = 2.3
    /// Kept below 7.5 turns per second on purpose: the rotor has four-fold
    /// symmetry, so on a 60 Hz display anything faster moves more than half a
    /// blade between frames and starts to look like it is turning backwards.
    private static let fastestRate = 6.0
}

final class TelemetryService {

    /// Cadence while only the menu bar icon is watching, and while the panel is
    /// open. The idle timer carries generous leeway so the kernel can coalesce
    /// its wake-ups with other timers instead of waking the CPU on its own.
    private static let idleInterval: TimeInterval = 2
    private static let activeInterval: TimeInterval = 1
    private static let idleLeeway: DispatchTimeInterval = .milliseconds(750)
    private static let activeLeeway: DispatchTimeInterval = .milliseconds(100)

    private static let historyLength = 60

    private let queue = DispatchQueue(label: "com.Amaury.Fan.telemetry", qos: .utility)
    private let sensors = SensorReader()
    private let system = SystemLoadReader()

    private var timer: DispatchSourceTimer?
    private var isDetailed = false
    private var hasDiscovered = false
    private var hasSweptDetail = false
    private var history: [Double] = []
    /// The running picture. Keeping it between ticks means the panel opens
    /// already populated instead of filling in — and visibly growing — a second
    /// later.
    private var current = Telemetry()

    /// Called on the main queue whenever a fresh sample is available.
    var onUpdate: ((Telemetry) -> Void)?

    var isAvailable: Bool { sensors != nil }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.schedule() }
    }

    /// Suspends sampling entirely — used when nothing can see the icon.
    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Turns the full sweep — temperatures, power, memory, network — on and off
    /// as the stats panel opens and closes.
    func setDetailed(_ detailed: Bool) {
        queue.async { [weak self] in
            guard let self, self.isDetailed != detailed else { return }
            self.isDetailed = detailed
            // Throughput measured since the panel was last open would be an
            // average over minutes; start the rate afresh.
            if detailed { self.system.resetNetworkBaseline() }
            if self.timer != nil { self.schedule() }
        }
    }

    // MARK: - Timer

    private func schedule() {
        timer?.cancel()
        discoverIfNeeded()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(),
                       repeating: isDetailed ? Self.activeInterval : Self.idleInterval,
                       leeway: isDetailed ? Self.activeLeeway : Self.idleLeeway)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    private func discoverIfNeeded() {
        guard !hasDiscovered, let sensors else { return }
        hasDiscovered = true
        sensors.discover()
    }

    // MARK: - Sampling

    private func sample() {
        // The very first sweep is always a full one, so every section of the
        // panel has something to show the moment it is first opened.
        let detailed = isDetailed || !hasSweptDetail

        // Cheap enough to keep running always, which is what keeps the panel's
        // sparkline populated the moment it opens.
        current.cpu = system.cpuLoad()
        history.append(current.cpu.busy)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        current.cpuHistory = history

        if let sensors {
            current.fans = sensors.fans()
            if detailed {
                current.temperatures = sensors.temperatures()
                current.power = sensors.power()
            }
        }

        if detailed {
            current.memory = system.memoryLoad()
            current.network = system.networkLoad()
            hasSweptDetail = true
        }

        let result = current
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(result)
        }
    }
}
