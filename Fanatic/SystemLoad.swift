//
//  SystemLoad.swift
//  Fanatic
//
//  CPU, memory and network figures, straight from the kernel: no shelling out
//  to `top` or `netstat`, so a refresh costs a few microseconds.
//

import AppKit
import Darwin
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
    var swapUsed: UInt64 = 0

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

/// One application and everything it has launched, e.g. a browser together
/// with its renderer helpers.
struct AppUsage: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    var cpu = 0.0           // 0...1 of the whole machine, like `CPULoad.busy`
    var bytes: UInt64 = 0
}

/// A process the system cannot confuse with a later one: PIDs are recycled,
/// a PID together with its start time is not.
struct ProcessIdentity: Hashable {
    let pid: pid_t
    let started: UInt64          // microseconds since 1970
}

/// A process tree running behind the user's back: no window, no Dock tile, no
/// menu bar item, launched by launchd rather than by any app on screen. A
/// booted simulator is the typical case — hundreds of processes and no sign of
/// them anywhere.
struct BackgroundProcess: Identifiable {
    let id: ProcessIdentity
    let name: String
    let path: String
    let icon: NSImage?
    var cpu = 0.0           // 0...1 of the whole machine, like `AppUsage.cpu`
    var bytes: UInt64 = 0
    var processCount = 0
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
    private var previousAppCPU: (nanoseconds: [pid_t: UInt64], timestamp: CFAbsoluteTime)?

    private static let tickNanoseconds: Double = {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

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

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }

        let pageSize = UInt64(vm_kernel_page_size)
        // Internal pages minus what can be reclaimed on demand: this is what
        // Activity Monitor calls "App Memory".
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemoryLoad(total: ProcessInfo.processInfo.physicalMemory,
                          app: internalPages.subtractingReportingOverflow(purgeable).partialValue * pageSize,
                          wired: UInt64(stats.wire_count) * pageSize,
                          compressed: UInt64(stats.compressor_page_count) * pageSize,
                          swapUsed: swap.xsu_used)
    }

    /// Whether `processLoad` has a previous reading to measure CPU against.
    var hasAppBaseline: Bool { previousAppCPU != nil }

    /// The Dock applications weighing most on the machine, and the background
    /// processes worth knowing about, each heaviest first.
    ///
    /// The weight is a share of all CPU cores plus a share of RAM: one busy
    /// core out of ten counts as much as a tenth of memory. A purely memory
    /// ranking would be all idle editors and browsers; a purely CPU one would
    /// reshuffle every second.
    ///
    /// Each app is charged for its whole process tree, so a browser counts its
    /// renderer helpers and a terminal the shells running in it. XPC services
    /// are parented to launchd rather than to the app, and are not counted.
    ///
    /// CPU is measured since the previous call, so the first call after
    /// `resetAppBaseline` reports none.
    func processLoad(appLimit: Int, backgroundLimit: Int) -> (apps: [AppUsage], background: [BackgroundProcess]) {
        let table = Self.processTable()
        let now = CFAbsoluteTimeGetCurrent()
        let previous = previousAppCPU
        let elapsed = previous.map { now - $0.timestamp } ?? 0
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let memory = Double(ProcessInfo.processInfo.physicalMemory)
        var cpuTimes: [pid_t: UInt64] = [:]

        func measure(_ root: pid_t) -> (cpu: Double, bytes: UInt64, count: Int) {
            var busy: UInt64 = 0, bytes: UInt64 = 0, count = 0
            var pending = [root]
            while let pid = pending.popLast() {
                if let reading = Self.usage(of: pid) {
                    bytes += reading.bytes
                    count += 1
                    cpuTimes[pid] = reading.cpuNanoseconds
                    // A process that started since the last call ran entirely
                    // within the interval.
                    if let previous {
                        let before = previous.nanoseconds[pid] ?? 0
                        busy += reading.cpuNanoseconds > before ? reading.cpuNanoseconds - before : 0
                    }
                }
                // launchd and the kernel are their own ancestors; never walk back up.
                pending += (table.children[pid] ?? []).filter { $0 > 1 && $0 != pid }
            }
            let cpu = elapsed > 0.05 ? min(Double(busy) / (elapsed * 1e9) / cores, 1) : 0
            return (cpu, bytes, count)
        }

        let running = NSWorkspace.shared.runningApplications
        let apps = running.compactMap { app -> AppUsage? in
            guard app.activationPolicy == .regular else { return nil }
            let tree = measure(app.processIdentifier)
            guard tree.bytes > 0 else { return nil }
            return AppUsage(id: app.processIdentifier,
                            name: app.localizedName ?? app.bundleIdentifier ?? "—",
                            icon: app.icon, cpu: tree.cpu, bytes: tree.bytes)
        }

        // Anything with a Dock tile or a menu bar item is in plain sight, and so
        // are the XPC services living inside its bundle.
        let visible = running.filter { $0.activationPolicy != .prohibited }
        let visiblePIDs = Set(visible.map(\.processIdentifier))
        let visibleBundles = visible.compactMap { $0.bundleURL.map { $0.path + "/" } }
        let user = getuid()

        var background: [BackgroundProcess] = []
        for entry in table.entries.values
        where entry.parent == 1 && entry.owner == user
            && entry.identity.pid != getpid() && !visiblePIDs.contains(entry.identity.pid) {
            guard let path = Self.executablePath(of: entry.identity.pid),
                  !Self.belongsToSystem(path),
                  !visibleBundles.contains(where: path.hasPrefix) else { continue }
            let tree = measure(entry.identity.pid)
            guard tree.cpu >= Self.backgroundCPUFloor || tree.bytes >= Self.backgroundMemoryFloor else { continue }
            let label = describe(path)
            background.append(BackgroundProcess(id: entry.identity, name: label.name, path: path,
                                                icon: label.icon, cpu: tree.cpu, bytes: tree.bytes,
                                                processCount: tree.count))
        }

        previousAppCPU = (cpuTimes, now)
        let weight = { (cpu: Double, bytes: UInt64) in cpu + Double(bytes) / memory }
        return (Array(apps.sorted { weight($0.cpu, $0.bytes) > weight($1.cpu, $1.bytes) }.prefix(appLimit)),
                Array(background.sorted { weight($0.cpu, $0.bytes) > weight($1.cpu, $1.bytes) }.prefix(backgroundLimit)))
    }

    /// Forgets the CPU times, so the next reading starts a fresh interval
    /// rather than averaging over however long the panel was closed.
    func resetAppBaseline() {
        previousAppCPU = nil
    }

    // MARK: Background processes

    /// Below both of these, a background process is part of the furniture:
    /// a sync agent or an updater sitting idle is not worth a row.
    private static let backgroundCPUFloor = 0.01
    private static let backgroundMemoryFloor: UInt64 = 250 << 20

    /// Names and icons, by executable path: looking up an icon reads the
    /// bundle from disk, and the same handful of processes come back every
    /// few seconds.
    private var descriptions: [String: (name: String, icon: NSImage?)] = [:]

    /// Ends a background process and everything it launched: asked to quit
    /// first, so it can clean up. Returns the processes it signalled, to hand
    /// to `forceQuit` for whatever is still around a moment later.
    func terminate(_ identity: ProcessIdentity) -> [ProcessIdentity] {
        // The PID may have been reused since the panel last looked.
        guard Self.processTable().entries[identity.pid]?.identity == identity else { return [] }

        // Frozen first, so it cannot relaunch the children being stopped
        // under it — launchd_sim would otherwise bring them straight back, as
        // orphans nobody can trace to it any more.
        guard kill(identity.pid, SIGSTOP) == 0 else {
            NSLog("Fanatic: cannot stop process \(identity.pid) — \(String(cString: strerror(errno)))")
            return []
        }
        defer { kill(identity.pid, SIGCONT) }

        let table = Self.processTable()
        var tree: [ProcessIdentity] = []
        var pending = [identity.pid]
        while let pid = pending.popLast() {
            if let entry = table.entries[pid] { tree.append(entry.identity) }
            pending += (table.children[pid] ?? []).filter { $0 > 1 && $0 != pid }
        }
        for member in tree { kill(member.pid, SIGTERM) }
        return tree
    }

    /// Kills whatever `terminate` asked to quit and is still running.
    func forceQuit(_ tree: [ProcessIdentity]) {
        let entries = Self.processTable().entries
        for member in tree where entries[member.pid]?.identity == member {
            kill(member.pid, SIGKILL)
        }
    }

    /// Daemons and agents that ship with macOS. Plenty of them run as the user,
    /// and stopping one at random can take the whole session down with it.
    private static func belongsToSystem(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/private/", "/Library/Apple/"]
            .contains(where: path.hasPrefix)
    }

    /// The name people know the process by: the simulator runtime it belongs
    /// to, else the app bundle it ships in, else its own executable name.
    private func describe(_ path: String) -> (name: String, icon: NSImage?) {
        if let cached = descriptions[path] { return cached }

        let components = path.split(separator: "/").map(String.init)
        let description: (name: String, icon: NSImage?)
        if let runtime = components.first(where: { $0.hasSuffix(".simruntime") }) {
            // ".../iOS 27.0.simruntime/.../sbin/launchd_sim"
            let simulator = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator")
            description = ("Simulateur \((runtime as NSString).deletingPathExtension)",
                           simulator.map { NSWorkspace.shared.icon(forFile: $0.path) })
        } else if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundle = "/" + components[...index].joined(separator: "/")
            description = ((components[index] as NSString).deletingPathExtension,
                           NSWorkspace.shared.icon(forFile: bundle))
        } else {
            description = (components.last ?? path, nil)
        }
        descriptions[path] = description
        return description
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Process table

    private struct ProcessEntry {
        let identity: ProcessIdentity
        let parent: pid_t
        let owner: uid_t
    }

    /// Every process, by PID, and the children of each. Listing processes this
    /// way is allowed inside the sandbox, unlike `proc_listallpids`.
    private static func processTable() -> (entries: [pid_t: ProcessEntry], children: [pid_t: [pid_t]]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0 else { return ([:], [:]) }
        // Headroom for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(),
                                     count: length / MemoryLayout<kinfo_proc>.stride + 32)
        length = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &processes, &length, nil, 0) == 0 else { return ([:], [:]) }

        var entries: [pid_t: ProcessEntry] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for process in processes.prefix(length / MemoryLayout<kinfo_proc>.stride) {
            let pid = process.kp_proc.p_pid
            let started = process.kp_proc.p_un.__p_starttime
            entries[pid] = ProcessEntry(
                identity: ProcessIdentity(pid: pid,
                                          started: UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec)),
                parent: process.kp_eproc.e_ppid,
                owner: process.kp_eproc.e_ucred.cr_uid)
            children[process.kp_eproc.e_ppid, default: []].append(pid)
        }
        return (entries, children)
    }

    /// Memory is the figure Activity Monitor shows in its Memory column: it
    /// includes pages that have been compressed or swapped out. Reading it
    /// needs the `process-info-rusage` sandbox exception; without it, falls
    /// back to the resident size, which leaves those pages out and reads low
    /// under pressure. CPU time is total user and system time since launch.
    private static func usage(of pid: pid_t) -> (bytes: UInt64, cpuNanoseconds: UInt64)? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if result == 0 {
            return (usage.ri_phys_footprint, nanoseconds(usage.ri_user_time + usage.ri_system_time))
        }

        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { return nil }
        return (task.pti_resident_size, nanoseconds(task.pti_total_user + task.pti_total_system))
    }

    /// Both CPU time counters are in Mach ticks, not nanoseconds as documented:
    /// 41.67 ns each on Apple Silicon.
    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        UInt64(Double(ticks) * tickNanoseconds)
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
                // step backwards rather than reporting a negative rate. The
                // check comes before subtracting: unsigned, the step back
                // wraps to an absurd rate that crashes the panel's formatter.
                if totalIn >= previous.inBytes {
                    load.bytesInPerSecond = Double(totalIn - previous.inBytes) / elapsed
                }
                if totalOut >= previous.outBytes {
                    load.bytesOutPerSecond = Double(totalOut - previous.outBytes) / elapsed
                }
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
        guard let store = SCDynamicStoreCreate(nil, "Fanatic" as CFString, nil, nil),
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
