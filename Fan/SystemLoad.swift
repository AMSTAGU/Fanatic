//
//  SystemLoad.swift
//  Fan
//
//  CPU, memory and network figures, straight from the kernel: no shelling out
//  to `top` or `netstat`, so a refresh costs a few microseconds.
//

import Darwin
import Foundation
import SystemConfiguration

// MARK: - Model

struct CPULoad {
    var user = 0.0          // 0...1
    var system = 0.0
    var idle = 1.0

    var busy: Double { min(max(1 - idle, 0), 1) }
}

struct MemoryLoad {
    var total: UInt64 = 0
    var app: UInt64 = 0          // anonymous pages held by applications
    var wired: UInt64 = 0        // pages the kernel cannot page out
    var compressed: UInt64 = 0

    var used: UInt64 { app + wired + compressed }

    var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    /// Rough stand-in for Activity Monitor's memory pressure: the share of RAM
    /// the system cannot simply reclaim.
    var pressureFraction: Double {
        total > 0 ? Double(wired + compressed) / Double(total) : 0
    }
}

struct NetworkLoad {
    var interfaceName = "—"        // e.g. "Wi-Fi"
    var address: String?
    var bytesInPerSecond = 0.0
    var bytesOutPerSecond = 0.0
}

// MARK: - Reader

final class SystemLoadReader {

    private var previousCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousCounters: (inBytes: UInt64, outBytes: UInt64, timestamp: CFAbsoluteTime)?

    // MARK: CPU

    /// Ticks are cumulative since boot, so the first call has nothing to compare
    /// against and reports an idle machine.
    func cpuLoad() -> CPULoad {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CPULoad() }

        let ticks = (user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                     idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousCPUTicks = ticks }

        guard let previous = previousCPUTicks else { return CPULoad() }
        let user = Double(ticks.user &- previous.user) + Double(ticks.nice &- previous.nice)
        let system = Double(ticks.system &- previous.system)
        let idle = Double(ticks.idle &- previous.idle)
        let total = user + system + idle
        guard total > 0 else { return CPULoad() }

        return CPULoad(user: user / total, system: system / total, idle: idle / total)
    }

    // MARK: Memory

    func memoryLoad() -> MemoryLoad {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryLoad() }

        let pageSize = UInt64(vm_kernel_page_size)
        // Internal pages minus what can be reclaimed on demand: this is what
        // Activity Monitor calls "App Memory".
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryLoad(total: ProcessInfo.processInfo.physicalMemory,
                          app: internalPages.subtractingReportingOverflow(purgeable).partialValue * pageSize,
                          wired: UInt64(stats.wire_count) * pageSize,
                          compressed: UInt64(stats.compressor_page_count) * pageSize)
    }

    // MARK: Network

    func networkLoad() -> NetworkLoad {
        var load = NetworkLoad()
        guard let primary = Self.primaryInterface() else { return load }
        load.interfaceName = Self.displayName(for: primary) ?? primary

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return load }
        defer { freeifaddrs(head) }

        var totalIn: UInt64 = 0, totalOut: UInt64 = 0

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard String(cString: interface.ifa_name) == primary,
                  let address = interface.ifa_addr else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { break }
                totalIn = UInt64(data.pointee.ifi_ibytes)
                totalOut = UInt64(data.pointee.ifi_obytes)
            case AF_INET:
                load.address = Self.presentationAddress(of: address, length: socklen_t(address.pointee.sa_len))
            default:
                break
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        if let previous = previousCounters {
            let elapsed = now - previous.timestamp
            if elapsed > 0.05 {
                // Counters are 32-bit on some interfaces and wrap; ignore the
                // step backwards rather than reporting a negative rate.
                load.bytesInPerSecond = max(0, Double(totalIn &- previous.inBytes)) / elapsed
                load.bytesOutPerSecond = max(0, Double(totalOut &- previous.outBytes)) / elapsed
            }
        }
        previousCounters = (totalIn, totalOut, now)
        return load
    }

    /// Forgets the byte counters, so the next reading starts a fresh interval
    /// rather than averaging over however long the app was not looking.
    func resetNetworkBaseline() {
        previousCounters = nil
    }

    // MARK: Interface naming

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Fan" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    /// Turns a BSD name such as "en0" into the label the user sees in System
    /// Settings, e.g. "Wi-Fi".
    private static func displayName(for bsdName: String) -> String? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in interfaces
        where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return nil
    }

    private static func presentationAddress(of address: UnsafeMutablePointer<sockaddr>,
                                            length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }
}
