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
}

struct StatsPanel: View {

    let store: TelemetryStore

    var onToggleLaunchAtLogin: () -> Void
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
