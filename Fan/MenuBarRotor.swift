//
//  MenuBarRotor.swift
//  Fan
//
//  The menu bar rotor. The glyph is handed to the status item as a template
//  image so that AppKit — not this app — decides its colour: the menu bar's
//  tint changes with the display it is on and with which screen has focus, and
//  none of that is visible from inside the process.
//
//  The spin is then a rotation of the button's own layer, which is the cheap
//  way round: AppKit tints the glyph once, the render server turns the finished
//  pixels, and the app itself burns nothing to keep the blades moving. Handing
//  the button a new image every frame instead costs a round trip to the window
//  server each time — it renegotiates the item's geometry on every redraw —
//  which measured 8% of a core against 0.05% for this.
//
//  There is one thing the layer cannot do. While the panel is open the button
//  draws its selection behind the glyph, into that same layer, and a turning
//  layer would turn the selection with it. So for as long as the item is
//  highlighted the rotor falls back to swapping pre-rendered frames, which
//  leaves the button's own drawing upright. The phase is carried across in both
//  directions, so the blades never jump between the two.
//

import AppKit

final class MenuBarRotor: NSObject {

    /// Frames in a full turn: one per degree. Only the fallback uses them.
    private static let frameCount = 360
    /// How far the blades may travel between two redraws, in the fallback.
    private static let degreesPerRedraw: Double = 6
    private static let slowestRedraw: Float = 10
    private static let fastestRedraw: Float = 120

    private let button: NSStatusBarButton
    /// Cut on first use and kept: a full turn is a few megabytes of 18 point
    /// bitmaps, and the rotor comes back to every one of them.
    private var frames: [NSImage?]
    private var link: CADisplayLink?

    /// Position in the turn, in turns. Authoritative only while frames are
    /// driving; the layer keeps its own clock otherwise.
    private var phase: Double = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var shownFrame = -1

    /// Desired rate, remembered across suspensions.
    private var targetRevolutionsPerSecond: Double = 0
    private var isSuspended = false

    /// Menu bar items draw a selection behind their content while their panel
    /// is open, and that selection must not turn with the blades.
    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            isHighlighted ? driveWithFrames() : driveWithLayer()
        }
    }

    init(button: NSStatusBarButton) {
        self.button = button
        self.frames = Array(repeating: nil, count: Self.frameCount)
        super.init()

        button.imagePosition = .imageOnly
        button.wantsLayer = true
        show(frame: 0)

        // Asked of the button rather than of a screen: AppKit re-targets the
        // link by itself when the menu bar the status item lives in moves to
        // another display, which is the same move that changes its refresh rate.
        let link = button.displayLink(target: self, selector: #selector(tick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link

        driveWithLayer()
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
        isHighlighted ? applyToFrames() : applyToLayer()
    }

    // MARK: - Spinning the layer

    private func driveWithLayer() {
        link?.isPaused = true

        // The layer carries the whole angle, so the image under it stays upright.
        show(frame: 0)
        centreTheAnchor()
        if button.layer?.animation(forKey: Self.spinKey) == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi          // clockwise, like a real rotor
            spin.duration = 1                       // one turn per second at speed 1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            button.layer?.add(spin, forKey: Self.spinKey)
        }
        applyToLayer()
    }

    /// Re-anchors the layer's clock: `localTime = (hostTime - beginTime) * speed
    /// + timeOffset`, so pinning the offset to the phase the rotor is already at
    /// and the start to now changes the rate without moving the blades.
    private func applyToLayer() {
        guard let layer = button.layer else { return }
        centreTheAnchor()
        layer.timeOffset = phaseOnLayer()
        layer.beginTime = CACurrentMediaTime()
        layer.speed = Float(effectiveRevolutionsPerSecond)
    }

    /// Moves the layer's anchor to the middle of the button.
    ///
    /// A view's backing layer is anchored at its corner, and a rotation turns
    /// about the anchor — so left alone the rotor swings around the bottom left
    /// of the status item instead of spinning on its hub. The middle of the
    /// button is also exactly where the hub is: AppKit centres the image, and
    /// the image is centred on the hub. Re-applied rather than set once, since
    /// AppKit owns this geometry and rewrites it whenever the button is laid
    /// out — which happens when the item is dragged along the menu bar.
    private func centreTheAnchor() {
        guard let layer = button.layer else { return }
        let middle = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let centred = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != centred || layer.position != middle else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = centred
        layer.position = middle
        CATransaction.commit()
    }

    /// Where the blades are now, in turns, read back from what is on screen.
    private func phaseOnLayer() -> Double {
        guard let layer = button.layer else { return phase }
        guard let angle = (layer.presentation() ?? layer)
            .value(forKeyPath: "transform.rotation.z") as? Double
        else { return phase }
        // The animation runs a turn per second of local time, backwards.
        return (-angle / (2 * .pi)).truncatingRemainder(dividingBy: 1) + (angle > 0 ? 1 : 0)
    }

    private static let spinKey = "spin"

    // MARK: - Spinning by frames

    private func driveWithFrames() {
        phase = phaseOnLayer()
        // Back to an upright layer, and to a frame that stands where the layer
        // had turned to.
        button.layer?.speed = 1
        button.layer?.timeOffset = 0
        button.layer?.beginTime = 0
        button.layer?.removeAnimation(forKey: Self.spinKey)
        show(frame: frameIndex(for: phase))
        lastTimestamp = 0
        applyToFrames()
    }

    private func applyToFrames() {
        guard let link else { return }
        let rate = effectiveRevolutionsPerSecond

        guard rate > 0 else {
            link.isPaused = true
            return
        }

        // Every redraw costs that round trip, so ask for no more of them than
        // the speed the rotor is turning at actually needs.
        let wanted = min(Self.fastestRedraw,
                         max(Self.slowestRedraw, Float(rate * 360 / Self.degreesPerRedraw)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Self.slowestRedraw,
                                                        maximum: Self.fastestRedraw,
                                                        preferred: wanted)
        if link.isPaused {
            // The clock restarts with the blades: the pause is not time the
            // rotor spent turning.
            lastTimestamp = 0
            link.isPaused = false
        }
    }

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
        show(frame: frameIndex(for: phase))
    }

    // MARK: - Frames

    private func frameIndex(for phase: Double) -> Int {
        let index = Int(phase * Double(Self.frameCount)) % Self.frameCount
        return index < 0 ? index + Self.frameCount : index
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
