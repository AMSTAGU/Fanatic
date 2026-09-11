//
//  MenuBarRotor.swift
//  Fan
//
//  The menu bar rotor. The glyph is handed to the status item as a template
//  image so that AppKit — not this app — decides its colour: the menu bar's
//  tint changes with the display it is on and with which screen has focus, and
//  none of that is visible from inside the process. The price is that the spin
//  can no longer be a single Core Animation animation on a layer of our own:
//  it is driven here instead, by swapping pre-rendered frames.
//
//  What makes that look like motion rather than ticking is where the frames
//  come from and when they land. A display link paces them against the screen's
//  own refresh — the display the status item is actually on, at the rate it
//  actually runs — so no frame is ever shown late or twice, and the frames
//  themselves are cut every degree, fine enough that the step between two of
//  them disappears. The link is paused whenever the blades are still.
//

import AppKit

final class MenuBarRotor: NSObject {

    /// Frames in a full turn: one per degree.
    private static let frameCount = 360
    /// How far the blades are allowed to travel between two frames. Three
    /// degrees is below what the eye resolves at this size, and asking for it
    /// rather than for every refresh is what keeps a slow drift cheap.
    private static let degreesPerFrame: Double = 3
    private static let slowestRefresh: Float = 10
    private static let fastestRefresh: Float = 120

    private let button: NSStatusBarButton
    /// Cut on first use and kept: a full turn is a few megabytes of 18 point
    /// bitmaps, and the rotor comes back to every one of them.
    private var frames: [NSImage?]
    private var link: CADisplayLink?

    /// Position in the turn, in turns. Accumulated rather than derived from a
    /// start time, so a change of rate never moves the blades.
    private var phase: Double = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var shownFrame = -1

    /// Desired rate, remembered across suspensions.
    private var targetRevolutionsPerSecond: Double = 0
    private var isSuspended = false

    init(button: NSStatusBarButton) {
        self.button = button
        self.frames = Array(repeating: nil, count: Self.frameCount)
        super.init()

        button.imagePosition = .imageOnly
        show(frame: 0)

        // Asked of the button rather than of a screen: AppKit re-targets the
        // link by itself when the menu bar the status item lives in moves to
        // another display, which is the same move that changes its refresh rate.
        let link = button.displayLink(target: self, selector: #selector(tick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    deinit { link?.invalidate() }

    // MARK: - Rate

    /// Sets the visual rate, in turns per second.
    func setRevolutionsPerSecond(_ rate: Double) {
        targetRevolutionsPerSecond = max(0, rate)
        apply()
    }

    /// Freezes the rotor when nobody can see it — display asleep, the machine
    /// going to sleep, or reduced motion turned on.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        apply()
    }

    private var effectiveRevolutionsPerSecond: Double {
        isSuspended ? 0 : targetRevolutionsPerSecond
    }

    private func apply() {
        guard let link else { return }
        let rate = effectiveRevolutionsPerSecond

        guard rate > 0 else {
            link.isPaused = true
            return
        }

        let wanted = min(Self.fastestRefresh,
                         max(Self.slowestRefresh,
                             Float(rate * 360 / Self.degreesPerFrame)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Self.slowestRefresh,
                                                        maximum: Self.fastestRefresh,
                                                        preferred: wanted)
        if link.isPaused {
            // The clock restarts with the blades: the pause is not time the
            // rotor spent turning.
            lastTimestamp = 0
            link.isPaused = false
        }
    }

    // MARK: - Spin

    /// Advances to the frame for the moment this one will actually be on screen,
    /// which is `targetTimestamp` — using "now" instead would leave the rotor
    /// permanently one frame of latency behind, and jitter by however long the
    /// callback itself took.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = lastTimestamp > 0 ? now - lastTimestamp : 0
        lastTimestamp = now

        phase = (phase + effectiveRevolutionsPerSecond * elapsed)
            .truncatingRemainder(dividingBy: 1)
        show(frame: Int(phase * Double(Self.frameCount)) % Self.frameCount)
    }

    private func show(frame index: Int) {
        guard index != shownFrame else { return }
        guard let image = image(at: index) else { return }
        shownFrame = index
        button.image = image
    }

    private func image(at index: Int) -> NSImage? {
        if let cached = frames[index] { return cached }
        let image = RotorGlyph.frame(turn: Double(index) / Double(Self.frameCount))
        frames[index] = image
        return image
    }
}
