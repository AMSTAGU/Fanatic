//
//  RotorGlyph.swift
//  Fan
//
//  Renders one frame of the rotor. Nothing here picks a colour: the menu bar
//  tints template images itself, per display and per focus state, and that is
//  the only tint that stays in step with the system's own status items.
//

import AppKit

enum RotorGlyph {

    static let symbolName = "fanblades.fill"
    /// Point size of the glyph inside the status item.
    static let pointSize: CGFloat = 18

    /// The rotor at `turn` of a full revolution, as a template image.
    ///
    /// Each frame carries a 1× and a 2× representation, so the menu bar picks
    /// the right one as the status item moves between displays.
    static func frame(turn: Double) -> NSImage? {
        guard let symbol else { return nil }

        // Clockwise, like a real rotor.
        let angle = -2 * CGFloat.pi * CGFloat(turn)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [CGFloat(1), CGFloat(2)] {
            guard let representation = representation(of: symbol, angle: angle, scale: scale)
            else { return nil }
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        return image
    }

    /// Resolved once: every frame is the same artwork under a different rotation.
    private static let symbol: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ventilateur")?
            .withSymbolConfiguration(configuration)
    }()

    /// The frame at `angle`, rasterised at `scale` pixels per point.
    ///
    /// The symbol's artwork is centred within its own box, so aspect-fitting it
    /// into a square canvas puts its axis of rotation on the canvas centre —
    /// which is what keeps the blades from wobbling from frame to frame. The
    /// artwork also stays well inside that square at every angle: fitted to 18
    /// points it spans 14.25 upright and 17 at its widest diagonal, so no frame
    /// clips its own corners.
    private static func representation(of symbol: NSImage, angle: CGFloat,
                                       scale: CGFloat) -> NSBitmapImageRep? {
        let side = Int((pointSize * scale).rounded())
        guard side > 0,
              let context = CGContext(data: nil,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let fitted = symbol.size.fitted(in: CGSize(width: pointSize, height: pointSize))
        let frame = CGRect(x: -fitted.width / 2, y: -fitted.height / 2,
                           width: fitted.width, height: fitted.height)

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: pointSize / 2, y: pointSize / 2)
        context.rotate(by: angle)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()

        guard let rendered = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: rendered)
        // In points, so the 1× and 2× frames are alternatives rather than sizes.
        representation.size = NSSize(width: pointSize, height: pointSize)
        return representation
    }
}

private extension CGSize {
    /// Aspect-fits the receiver inside `box`.
    func fitted(in box: CGSize) -> CGSize {
        guard width > 0, height > 0 else { return box }
        let factor = min(box.width / width, box.height / height)
        return CGSize(width: width * factor, height: height * factor)
    }
}
