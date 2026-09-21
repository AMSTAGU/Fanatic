//
//  MenuBarRotor.swift
//  Fanatic
//
//  The menu bar rotor. The glyph is handed to the status item as a template
//  image so that AppKit — not this app — decides its colour: the menu bar's
//  tint changes with the display it is on and with which screen has focus, and
//  none of that is visible from inside the process.
//
//  The spin is then a rotation of the layer AppKit puts the tinted glyph in,
//  which is the cheap way round: the glyph is tinted where the menu bar is
//  drawn, the render server turns it, and the app itself burns nothing to keep
//  the blades moving. Handing
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

    /// The layer AppKit hands the tinted glyph to: a sublayer of the button
    /// whose contents are the template image, tinted at render time by whoever
    /// draws the menu bar. That is the layer to turn, not the button's own.
    ///
    /// The button's layer is the root of what the menu bar hosts from another
    /// process, and that host owns its geometry and its clock: an anchor moved
    /// there, or a speed or time offset set on it, looks right from in here and
    /// never reaches the screen — the rotor swung about the corner and jumped
    /// every time the rate was re-applied. The sublayer is ours to animate, and
    /// it already spans the button with its anchor in the middle, which is
    /// where the image, and so the hub, is centred.
    private var glyphLayer: CALayer? {
        button.layer?.sublayers?.first { $0.contents != nil }
    }

    /// The layer the spin was last installed on. AppKit rebuilds the glyph's
    /// layer when the image changes, which silently takes the spin with it.
    private weak var spinningLayer: CALayer?
    /// Where the blades were, in turns, at `layerAnchorTime`, and how fast they
    /// have turned since: the rotor's position is worked out from these rather
    /// than read back from the screen, so a re-install never moves the blades.
    private var layerAnchorPhase: Double = 0
    private var layerAnchorTime: CFTimeInterval = 0
    private var layerRate: Double = 0

    private func layerPhase(at time: CFTimeInterval) -> Double {
        let turned = layerAnchorPhase + layerRate * (time - layerAnchorTime)
        let phase = turned.truncatingRemainder(dividingBy: 1)
        return phase < 0 ? phase + 1 : phase
    }

    private func driveWithLayer() {
        link?.isPaused = true

        // The layer carries the whole angle, so the image under it stays upright.
        show(frame: 0)
        layerAnchorPhase = phase
        layerAnchorTime = CACurrentMediaTime()
        layerRate = effectiveRevolutionsPerSecond
        spinningLayer = nil
        applyToLayer()
        // Setting the image can have AppKit rebuild the glyph's layer on its next
        // display pass, after the spin went onto the old one.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHighlighted else { return }
            self.applyToLayer()
        }
    }

    /// Installs the spin at the current rate, starting exactly where the blades
    /// already are. Runs on every telemetry tick, and does nothing unless the
    /// rate has really changed or AppKit has thrown the spin away.
    ///
    /// Speed and start both travel on the animation itself — an animation is
    /// immutable once added, so a new rate means a new animation, handed the
    /// phase the old one had reached as its time offset.
    private func applyToLayer() {
        guard let layer = glyphLayer else { return }
        let rate = effectiveRevolutionsPerSecond
        let intact = spinningLayer === layer && layer.animation(forKey: Self.spinKey) != nil
        guard !intact || abs(rate - layerRate) > 0.002 else { return }

        let now = CACurrentMediaTime()
        let phase = layerPhase(at: now)

        // Clockwise, like a real rotor — which is a negative angle only where y
        // runs up. The button's layer is flipped, and a turn expressed inside a
        // flipped parent comes out mirrored on screen, so the sign follows the
        // parent rather than being fixed: otherwise the blades would reverse
        // every time the panel opened and the frames took over.
        let clockwise = (layer.superlayer?.contentsAreFlipped() ?? false) ? 2 * Double.pi : -2 * Double.pi
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = clockwise
        spin.duration = 1                       // one turn per unit of animation time
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false
        spin.fillMode = .both
        spin.beginTime = layer.convertTime(now, from: nil)
        spin.timeOffset = phase
        spin.speed = Float(rate)                // zero holds the blades at `phase`

        if let previous = spinningLayer, previous !== layer {
            previous.removeAnimation(forKey: Self.spinKey)
        }
        layer.add(spin, forKey: Self.spinKey)   // replaces any spin already there
        spinningLayer = layer

        layerAnchorPhase = phase
        layerAnchorTime = now
        layerRate = rate
    }

    private static let spinKey = "spin"

    // MARK: - Spinning by frames

    private func driveWithFrames() {
        phase = layerPhase(at: CACurrentMediaTime())
        // Back to an upright glyph, showing a frame that stands where the layer
        // had turned to.
        spinningLayer?.removeAnimation(forKey: Self.spinKey)
        spinningLayer = nil
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
