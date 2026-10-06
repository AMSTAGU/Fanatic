//
//  StatsPanel.swift
//  Fanatic
//
//  The popover shown from the menu bar. It exists only while it is on screen,
//  and only then does the telemetry service gather the full picture.
//

import Observation
import SwiftUI

/// Bridges pushed telemetry into SwiftUI.
@Observable
final class TelemetryStore {
    var telemetry = Telemetry()
    var launchesAtLogin = false
    /// Set from the screen the panel is about to open on, so a Mac with more
    /// sensors than fit simply scrolls instead of running off the display.
    var maximumHeight: CGFloat = 900
    /// Background processes asked to quit, and when. They are hidden straight
    /// away rather than lingering until the next process sweep; one still
    /// running a few seconds later comes back, since stopping it failed.
    var terminating: [ProcessIdentity: Date] = [:]

    var backgroundProcesses: [BackgroundProcess] {
        let cutoff = Date(timeIntervalSinceNow: -5)
        return telemetry.backgroundProcesses.filter { (terminating[$0.id] ?? .distantPast) < cutoff }
    }
}

struct StatsPanel: View {

    let store: TelemetryStore

    var onTerminate: (BackgroundProcess) -> Void
    var onToggleLaunchAtLogin: () -> Void

    /// The order of the background rows while the pointer is over them. Two
    /// processes of similar weight trade places from one sweep to the next,
    /// and a row must not slide away just as it is being clicked.
    @State private var heldBackgroundOrder: [ProcessIdentity]?

    private var backgroundProcesses: [BackgroundProcess] {
        let current = store.backgroundProcesses
        guard let order = heldBackgroundOrder else { return current }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return order.compactMap { byID[$0] } + current.filter { !order.contains($0.id) }
    }
    var onQuit: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            sections
        }
        .frame(width: 286)
        .frame(maxHeight: store.maximumHeight)
        .scrollBounceBehavior(.basedOnSize)
        // The panel fits without scrolling on any normal display; the scroll
        // view is only a safety net for very short screens. Showing its
        // indicator would put a permanent bar down the side for anyone whose
        // system setting is "always show scroll bars".
        .scrollIndicators(.never)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            fans
            divider
            processor
            if !store.telemetry.temperatures.isEmpty {
                divider
                temperatures
            }
            divider
            memory
            // Right under the CPU and memory figures it accounts for.
            if !store.telemetry.topApps.isEmpty {
                divider
                apps
            }
            if !store.backgroundProcesses.isEmpty {
                divider
                background
            }
            divider
            network
            if !store.telemetry.power.isEmpty {
                divider
                power
            }
            divider
            footer
        }
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 14)
    }

    // MARK: - Sections

    private var processor: some View {
        let cpu = store.telemetry.cpu
        return Section(icon: "cpu", title: "CPU", value: Format.percent(cpu.busy)) {
            Sparkline(samples: store.telemetry.cpuHistory)
                .frame(height: 22)
                .padding(.bottom, 2)
            Row("Système", Format.percent(cpu.system))
            Row("Utilisateur", Format.percent(cpu.user))
            Row("Inactif", Format.percent(cpu.idle))
        }
    }

    private var memory: some View {
        let memory = store.telemetry.memory
        return Section(icon: "memorychip", title: "Mémoire",
                       value: Format.percent(memory.usedFraction)) {
            Row("Charge mémoire", Format.percent(memory.pressureFraction))
            Row("Mémoire des apps", Format.bytes(memory.app))
            Row("Mémoire réservée", Format.bytes(memory.wired))
            Row("Compressée", Format.bytes(memory.compressed))
            Row("Swap", Format.bytes(memory.swapUsed))
        }
    }

    private var apps: some View {
        Section(icon: "square.grid.2x2", title: "Apps gourmandes", value: nil) {
            // The icons make these rows taller than plain text rows; without
            // the extra room the first one crowds the title.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.telemetry.topApps) { app in
                    AppRow(app: app)
                }
            }
            .padding(.top, 4)
        }
    }

    private var background: some View {
        Section(icon: "eye.slash", title: "En arrière-plan", value: nil) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(backgroundProcesses) { process in
                    BackgroundRow(process: process) { onTerminate(process) }
                }
            }
            .padding(.top, 4)
            .onHover { inside in
                heldBackgroundOrder = inside ? backgroundProcesses.map(\.id) : nil
            }
        }
    }

    private var network: some View {
        let network = store.telemetry.network
        return Section(icon: "network", title: "Réseau", value: network.interfaceName) {
            if let address = network.address {
                Row("IP locale", address)
            }
            Row("Envoi", Format.rate(network.bytesOutPerSecond))
            Row("Réception", Format.rate(network.bytesInPerSecond))
        }
    }

    private var fans: some View {
        Section(icon: "fanblades", title: "Ventilateurs", value: nil) {
            if store.telemetry.fans.isEmpty {
                Row("Aucun ventilateur", "—")
            }
            ForEach(store.telemetry.fans) { fan in
                FanRow(fan: fan, showsIndex: store.telemetry.fans.count > 1)
            }
        }
    }

    private var temperatures: some View {
        Section(icon: "thermometer.medium", title: "Températures", value: nil) {
            ForEach(store.telemetry.temperatures) { group in
                Row(group.name,
                    Format.celsius(group.peak),
                    detail: group.sensorCount > 1 ? "moy. \(Format.celsius(group.average))" : nil)
            }
        }
    }

    private var power: some View {
        Section(icon: "bolt", title: "Puissance", value: nil) {
            ForEach(store.telemetry.power) { rail in
                Row(rail.name, Format.watts(rail.watts))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onToggleLaunchAtLogin) {
                Label {
                    Text("Au démarrage")
                } icon: {
                    Image(systemName: store.launchesAtLogin ? "checkmark.circle.fill" : "circle")
                }
            }
            Spacer()
            Button("Quitter", action: onQuit)
        }
        .buttonStyle(.accessoryBar)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let icon: String
    let title: String
    let value: String?
    @ViewBuilder var content: Content

    init(icon: String, title: String, value: String?, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.value = value
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let value {
                        Text(value)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                content
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct Row: View {
    let label: String
    let value: String
    let detail: String?

    init(_ label: String, _ value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// Laid out like `Row`, with the app's icon in front: memory as the quieter
/// detail, CPU as the value.
private struct AppRow: View {
    let app: AppUsage

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 14, height: 14)

            Text(app.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(Format.bytes(app.bytes)).foregroundStyle(.tertiary).lineLimit(1)
            Text(Format.percent(app.cpu))
                .lineLimit(1)
                // Wide enough for "100.0 %", so the memory column stays put
                // as the CPU figure changes width.
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// Laid out like `AppRow`. Hovering fades the row and swaps the CPU figure for
/// a cross; a click anywhere on it asks to confirm, since stopping the whole
/// process tree cannot be undone. Moving away drops the question.
private struct BackgroundRow: View {
    let process: BackgroundProcess
    var onTerminate: () -> Void

    @State private var isHovered = false
    @State private var isConfirming = false

    var body: some View {
        Group {
            if isConfirming { confirmation } else { summary }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minHeight: 16)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if !inside { isConfirming = false }
        }
        .help(process.processCount > 1
              ? "\(process.processCount) processus\n\(process.path)"
              : process.path)
    }

    private var summary: some View {
        Button {
            isConfirming = true
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let icon = process.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "gearshape").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 14, height: 14)

                Text(process.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(Format.bytes(process.bytes)).foregroundStyle(.tertiary).lineLimit(1)
                // Both stay laid out, so the row does not shift as the pointer
                // comes and goes.
                ZStack(alignment: .trailing) {
                    Text(Format.percent(process.cpu))
                        .lineLimit(1)
                        .opacity(isHovered ? 0 : 1)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .opacity(isHovered ? 1 : 0)
                }
                .frame(minWidth: 44, alignment: .trailing)
            }
            .opacity(isHovered ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Quitter \(process.name)")
    }

    private var confirmation: some View {
        HStack(spacing: 8) {
            Text("Quitter \(process.name) ?").lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Annuler") { isConfirming = false }
            Button("Quitter") {
                isConfirming = false
                onTerminate()
            }
            .foregroundStyle(.primary)
            .fontWeight(.semibold)
        }
    }
}

private struct FanRow: View {
    let fan: FanReading
    let showsIndex: Bool

    /// A hair of width so a slowly turning fan still registers, but nothing at
    /// all when it is genuinely stopped.
    private func width(in available: CGFloat) -> CGFloat {
        fan.isStopped ? 0 : max(3, available * fan.fractionOfMaximum)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(showsIndex ? "Ventilateur #\(fan.index + 1)" : "Ventilateur")
                Spacer(minLength: 8)
                Text(fan.isStopped ? "à l’arrêt" : Format.rpm(fan.rpm)).monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            // Filled from a standstill, so a stopped fan reads as empty.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.tint)
                        .frame(width: width(in: geometry.size.width))
                }
            }
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.55), value: fan.fractionOfMaximum)
        }
        .padding(.top, 1)
    }
}

private struct Sparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            let points = Array(samples.suffix(60))
            if points.count > 1 {
                let step = geometry.size.width / CGFloat(points.count - 1)
                let height = geometry.size.height

                let position = { (index: Int, value: Double) in
                    CGPoint(x: CGFloat(index) * step,
                            y: height - CGFloat(min(max(value, 0), 1)) * height)
                }

                let curve = Path { path in
                    for (index, value) in points.enumerated() {
                        let point = position(index, value)
                        index == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                }

                // The same curve, closed along the baseline, to shade underneath.
                let area = Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, value) in points.enumerated() {
                        path.addLine(to: position(index, value))
                    }
                    path.addLine(to: CGPoint(x: CGFloat(points.count - 1) * step, y: height))
                    path.closeSubpath()
                }

                ZStack {
                    area.fill(.tint.opacity(0.18))
                    curve.stroke(.tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - Formatting

private enum Format {
    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f %%", (fraction * 100).rounded(toPlaces: 1))
    }

    static func celsius(_ value: Double) -> String {
        String(format: "%.1f °C", value)
    }

    static func watts(_ value: Double) -> String {
        String(format: "%.2f W", value)
    }

    static func rpm(_ value: Double) -> String {
        "\(rpmFormatter.string(from: value as NSNumber) ?? "\(Int(value))") tr/min"
    }

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(byteFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond))))/s"
    }

    private static let rpmFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
