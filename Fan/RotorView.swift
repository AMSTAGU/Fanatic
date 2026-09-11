//
//  RotorView.swift
//  Fan
//
//  The menu bar rotor. The spin is a single infinite Core Animation animation
//  handed to the render server once: changing speed only re-anchors the layer's
//  clock, so the app itself burns no CPU while the blades turn.
//

import AppKit

final class RotorView: NSView {

    /// Point size of the glyph inside the status item.
    private static let glyphSize: CGFloat = 18
    /// Supersampling on top of the display scale, so the rotated bitmap stays
    /// clean at every angle.
    private static let oversample: CGFloat = 2

    private let rotorLayer = CALayer()
    private var currentRevolutionsPerSecond: Double = 0

    /// Menu bar items invert while their menu is open.
    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { renderGlyph() } }
    }

    /// Desired rate, remembered across suspensions.
    private var targetRevolutionsPerSecond: Double = 0
    private var isSuspended = false

    // MARK: - Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(rotorLayer)
        rotorLayer.contentsGravity = .resizeAspect
        rotorLayer.magnificationFilter = .trilinear
        rotorLayer.minificationFilter = .trilinear
        rotorLayer.speed = 0
        installSpin()
        renderGlyph()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The rotor sits on top of the status item's button purely as decoration;
    /// letting clicks pass straight through keeps the button's own action working.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Positioned without an implicit animation: the layer already carries one.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotorLayer.bounds = CGRect(x: 0, y: 0, width: Self.glyphSize, height: Self.glyphSize)
        rotorLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderGlyph()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderGlyph()
    }

    /// The menu bar can move between displays, which changes both the backing
    /// scale and the appearance the glyph has to match.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderGlyph()
    }

    // MARK: - Animation

    private func installSpin() {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi           // clockwise, like a real rotor
        spin.duration = 1                        // one turn per second at speed 1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        rotorLayer.add(spin, forKey: "spin")
    }

    /// Sets the visual rate, in turns per second. The layer's local clock is
    /// re-anchored so the blades never jump: only the rate changes, never the
    /// angle.
    func setRevolutionsPerSecond(_ rate: Double) {
        targetRevolutionsPerSecond = max(0, rate)
        guard !isSuspended else { return }
        apply(targetRevolutionsPerSecond)
    }

    /// Freezes the animation when nobody can see it — display asleep, menu bar
    /// hidden behind a full screen window, or reduced motion turned on.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        apply(suspended ? 0 : targetRevolutionsPerSecond)
    }

    private func apply(_ rate: Double) {
        guard abs(rate - currentRevolutionsPerSecond) > 0.002 else { return }
        currentRevolutionsPerSecond = rate

        // localTime = (hostTime - beginTime) * speed + timeOffset, so pinning
        // timeOffset to the current local time and beginTime to now keeps the
        // blades exactly where they are while the rate changes underneath.
        let localTime = rotorLayer.convertTime(CACurrentMediaTime(), from: nil)
        rotorLayer.speed = Float(rate)
        rotorLayer.timeOffset = localTime
        rotorLayer.beginTime = CACurrentMediaTime()
    }

    // MARK: - Glyph

    private func renderGlyph() {
        let scale = (window?.backingScaleFactor ?? 2) * Self.oversample

        // Resolved against the menu bar's own appearance rather than pinned to a
        // fixed colour: that is what lets the rotor sit at the same weight as
        // every other status item, dark menu bar or light.
        let color = effectiveAppearance.resolve {
            isHighlighted ? .selectedMenuItemTextColor : .labelColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotorLayer.contentsScale = scale
        rotorLayer.contents = RotorGlyph.image(color: color,
                                               pointSize: Self.glyphSize,
                                               scale: scale)
        CATransaction.commit()
    }
}

private extension NSAppearance {
    /// Resolves a dynamic colour against this appearance.
    ///
    /// Converting to a concrete colour space *inside* the block is the point:
    /// `NSColor.labelColor` is dynamic, and simply handing the object back
    /// would leave it to resolve later, at draw time, against whatever
    /// appearance happened to be current — which for an offscreen context is
    /// the light one. That is how a dark menu bar ends up with a black glyph.
    func resolve(_ body: () -> NSColor) -> NSColor {
        var color = NSColor.labelColor
        performAsCurrentDrawingAppearance {
            let dynamic = body()
            color = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        return color
    }
}
