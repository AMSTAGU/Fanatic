//
//  Sensors.swift
//  Fanatic
//
//  Everything read from the SMC: fans, temperatures and power rails.
//
//  Macs expose hundreds of thermal keys — this machine has 222 — far too many
//  to list one by one, and their per-core meaning changes with every chip. They
//  are grouped by key prefix instead, which stays truthful on any Mac.
//

import Foundation

// MARK: - Model

struct FanReading: Identifiable {
    let index: Int
    let rpm: Double
    let maximumRPM: Double

    var id: Int { index }

    /// Share of the fan's top speed, measured from a standstill, 0...1.
    ///
    /// Deliberately not measured from the fan's own minimum: this fan idles at
    /// 2 317 rpm, so a range-based figure would show a barely-audible fan at 4%
    /// and one that never stops at "zero". From zero, the reading matches what
    /// you can actually hear.
    var fractionOfMaximum: Double {
        guard maximumRPM > 0 else { return 0 }
        return min(max(rpm / maximumRPM, 0), 1)
    }

    var isStopped: Bool { rpm < 1 }
}

struct TemperatureGroup: Identifiable {
    let name: String
    let peak: Double
    let average: Double
    let sensorCount: Int

    var id: String { name }
}

struct PowerRail: Identifiable {
    let name: String
    let watts: Double

    var id: String { name }
}

// MARK: - Reader

final class SensorReader {

    /// Thermal sensor families, by SMC key prefix. Ordered as they are shown.
    private static let temperatureGroups: [(prefix: String, name: String)] = [
        ("Tp", "CPU perf."),
        ("Te", "CPU efficacité"),
        ("Tg", "GPU"),
        ("Ts", "Châssis"),
        ("TB", "Batterie"),
        ("TD", "SSD"),
        ("TW", "Wi-Fi"),
    ]

    /// Power rails worth showing, and what they actually measure.
    private static let powerRails: [(key: String, name: String)] = [
        ("PSTR", "Système total"),
        ("PDTR", "Entrée secteur"),
        ("PPBR", "Batterie"),
    ]

    private let smc: SMC
    private var fanCount = 0
    private var temperatureKeys: [(name: String, keys: [String])] = []
    private var availableRails: [(key: String, name: String)] = []

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
    }

    /// Walks the SMC key table once to learn what this Mac actually exposes.
    /// Costly enough (a few hundred milliseconds) to belong off the main thread,
    /// and done exactly once.
    func discover() {
        fanCount = smc.readNumber("FNum").map { Int($0) } ?? 0

        let keys = Set(smc.allKeys())
        temperatureKeys = Self.temperatureGroups.compactMap { group in
            let members = keys
                .filter { $0.hasPrefix(group.prefix) }
                .filter { key in
                    // Keep only keys that answer with a believable temperature.
                    guard let value = smc.readNumber(key) else { return false }
                    return value > 5 && value < 125
                }
                .sorted()
            return members.isEmpty ? nil : (group.name, members)
        }

        availableRails = Self.powerRails.filter { rail in
            keys.contains(rail.key) && smc.readNumber(rail.key) != nil
        }
    }

    // MARK: - Sampling

    func fans() -> [FanReading] {
        (0..<fanCount).compactMap { index in
            guard let rpm = smc.readNumber("F\(index)Ac") else { return nil }
            return FanReading(index: index,
                              rpm: rpm,
                              maximumRPM: smc.readNumber("F\(index)Mx") ?? 6000)
        }
    }

    func temperatures() -> [TemperatureGroup] {
        temperatureKeys.compactMap { group in
            let values = group.keys.compactMap { smc.readNumber($0) }
            guard let peak = values.max() else { return nil }
            return TemperatureGroup(name: group.name,
                                    peak: peak,
                                    average: values.reduce(0, +) / Double(values.count),
                                    sensorCount: values.count)
        }
    }

    func power() -> [PowerRail] {
        availableRails.compactMap { rail in
            guard let watts = smc.readNumber(rail.key) else { return nil }
            return PowerRail(name: rail.name, watts: watts)
        }
    }
}
