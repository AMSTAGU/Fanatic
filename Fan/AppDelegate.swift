//
//  AppDelegate.swift
//  Fan
//
//  Wires the telemetry service to the menu bar rotor and the stats panel, and
//  keeps both asleep whenever nobody can see them. This is a menu bar only
//  agent: no window, no dock tile.
//

import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private var rotor: MenuBarRotor?
    private let telemetry = TelemetryService()
    private let store = TelemetryStore()
    private let popover = NSPopover()
    private var latest = Telemetry()
    private var outsideClickMonitor: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        buildStatusItem()
        buildPanel()
        observeSystemEvents()

        telemetry.onUpdate = { [weak self] telemetry in
            self?.consume(telemetry)
        }

        guard telemetry.isAvailable else {
            statusItem.button?.toolTip = "Capteurs indisponibles"
            return
        }
        telemetry.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        telemetry.stop()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        // No air at all: the frame is already cut as close to the blades as
        // their sweep allows, so the item is exactly as wide as the rotor and
        // whatever gap shows either side is the menu bar's own.
        statusItem = NSStatusBar.system.statusItem(withLength: RotorGlyph.pointSize)

        guard let button = statusItem.button else { return }
        button.setAccessibilityLabel("Vitesse du ventilateur")
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        rotor = MenuBarRotor(button: button)
    }

    private func buildPanel() {
        let panel = StatsPanel(
            store: store,
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onQuit: { NSApp.terminate(nil) })

        let controller = NSHostingController(rootView: panel)
        // Without this the popover keeps whatever size the panel had on its
        // first layout — before any sensor data arrived — and the rest of the
        // content ends up behind a scroll bar.
        controller.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        popover.isShown ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard let button = statusItem.button else { return }
        store.telemetry = latest
        store.launchesAtLogin = SMAppService.mainApp.status == .enabled
        // Gather the full picture only while it is being looked at.
        telemetry.setDetailed(true)

        // An accessory app is not active by default. Activating *before* the
        // popover is shown matters twice over: the panel's own buttons respond
        // to the first click, and AppKit lays the popover out against the real
        // window position rather than a stale one — otherwise it can end up
        // hanging off the top of the screen.
        NSApp.activate()
        sizePanel(for: button)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Without a key window the panel draws in its inactive, washed-out
        // state — the same greying macOS gives any background window.
        popover.contentViewController?.view.window?.makeKey()
        // Set on the next turn of the run loop: the button clears its own
        // highlight while finishing the click that brought us here.
        DispatchQueue.main.async { button.isHighlighted = true }
        watchForOutsideClicks()
    }

    /// Keeps the panel inside the screen it opens on. Macs with more thermal
    /// sensors than this one produce a taller panel, and small displays leave
    /// less room for it.
    private func sizePanel(for button: NSStatusBarButton) {
        let screen = button.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 900) - Self.screenMargin
        store.maximumHeight = max(available, 200)
    }

    /// Breathing room between the panel and the edge of the screen.
    private static let screenMargin: CGFloat = 24

    private func closePanel() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.isHighlighted = false
        stopWatchingForOutsideClicks()
        telemetry.setDetailed(false)
    }

    /// A transient popover is dismissed by AppKit only once the owning app is
    /// active, and an accessory app frequently is not — which leaves the panel
    /// stranded on screen. Watching for a click anywhere else closes it the way
    /// people expect. Clicks inside the panel, and on the status item itself,
    /// are local events and never reach this monitor.
    private func watchForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Readings

    private func consume(_ telemetry: Telemetry) {
        latest = telemetry
        rotor?.setRevolutionsPerSecond(telemetry.rotorRevolutionsPerSecond)

        let tooltip = tooltip(for: telemetry)
        if tooltip != statusItem.button?.toolTip {
            statusItem.button?.toolTip = tooltip
        }

        // Feeding the store while the panel is closed would have SwiftUI
        // re-evaluate a view nobody is looking at, every single tick.
        if popover.isShown { store.telemetry = telemetry }
    }

    private func tooltip(for telemetry: Telemetry) -> String {
        guard let fan = telemetry.leadFan else { return "Aucun ventilateur détecté" }
        guard !fan.isStopped else { return "Ventilateur à l’arrêt" }
        return "\(Int(fan.rpm.rounded())) tr/min"
    }

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Fan: launch at login failed — \(error.localizedDescription)")
        }
        store.launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Power

    // Occlusion of the status item's window is deliberately *not* watched.
    // It looks like a free way to stop working while the menu bar is hidden
    // behind a full screen window, but that window reports itself occluded in
    // situations where the menu bar is plainly visible — and since sampling
    // only restarts on the next occlusion change, the app would sit there
    // showing nothing. Display sleep, below, is both reliable and the case
    // that actually saves power.

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(suspend),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resume),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(suspend),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resume),
                              name: NSWorkspace.didWakeNotification, object: nil)

        // Honour the system's reduced-motion setting.
        workspace.addObserver(self, selector: #selector(motionPreferenceChanged),
                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                              object: nil)
        applyMotionPreference()
    }

    @objc private func suspend() {
        rotor?.setSuspended(true)
        telemetry.stop()
    }

    @objc private func resume() {
        guard telemetry.isAvailable else { return }
        telemetry.start()
        applyMotionPreference()
    }

    @objc private func motionPreferenceChanged() {
        applyMotionPreference()
    }

    private func applyMotionPreference() {
        rotor?.setSuspended(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}
