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
    /// Pixels per point the master is drawn at.
    private static let sourceScale: CGFloat = 4

    /// The rotor at `turn` of a full revolution, as a template image.
    ///
    /// Each frame carries a 1× and a 2× representation, so the menu bar picks
    /// the right one as the status item moves between displays.
    static func frame(turn: Double) -> NSImage? {
        guard let master else { return nil }

        // Clockwise, like a real rotor.
        let angle = -2 * CGFloat.pi * CGFloat(turn)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [CGFloat(1), CGFloat(2)] {
            guard let representation = representation(of: master, angle: angle, scale: scale)
            else { return nil }
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        return image
    }

    /// The rotor upright, drawn once at four times the size it is shown at, and
    /// centred on its axis of rotation rather than on its own bounding box.
    ///
    /// Every frame is this one bitmap turned, never the symbol re-drawn at a new
    /// angle: the vector renderer snaps contours to the pixel grid, and it does
    /// it differently for every angle, so re-drawing makes the blades shimmer
    /// and thicken frame to frame. Turning finished pixels keeps the shape rigid,
    /// and the extra resolution is what the rotation gives away to interpolation.
    private static let master: CGImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: "Ventilateur")?
            .withSymbolConfiguration(configuration),
              let boxed = upright(symbol, shiftedBy: .zero)
        else { return nil }

        // Drawn a second time, about the axis found in the first. The hub sits
        // off the centre of the artwork's box — by 0.37 points, down and to the
        // right — and turning about the box centre is what makes the blades
        // wobble instead of spin. Measured rather than assumed: turned a quarter
        // turn about the box centre the rotor misses itself by 20% of its own
        // ink, and about this axis by 1%.
        return upright(symbol, shiftedBy: axisOffset(of: boxed))?.makeImage()
    }()

    /// The rotor drawn upright into a square canvas, its artwork aspect-fitted
    /// and then displaced by `offset` points.
    private static func upright(_ symbol: NSImage, shiftedBy offset: CGSize) -> CGContext? {
        let side = Int((pointSize * sourceScale).rounded())
        guard let context = CGContext(data: nil,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let fitted = symbol.size.fitted(in: CGSize(width: pointSize, height: pointSize))
        context.scaleBy(x: sourceScale, y: sourceScale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(x: (pointSize - fitted.width) / 2 + offset.width,
                               y: (pointSize - fitted.height) / 2 + offset.height,
                               width: fitted.width, height: fitted.height))
        NSGraphicsContext.restoreGraphicsState()

        return context
    }

    /// How far the rotor's axis sits from the centre of `canvas`, in points.
    ///
    /// Taken as the centroid of the ink: the blades are identical and evenly
    /// spaced around the hub, so their weight balances exactly on the point they
    /// turn about. Nothing in the symbol declares that point, and it is not the
    /// middle of the box the artwork is drawn in.
    private static func axisOffset(of canvas: CGContext) -> CGSize {
        guard let data = canvas.data else { return .zero }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let width = canvas.width, height = canvas.height, stride = canvas.bytesPerRow

        // Sampled at pixel centres — index plus a half — so the centroid lands
        // in the same coordinates as the canvas centre it is measured against,
        // and counted up from the bottom: the buffer's first row is the top of
        // the image, while the context draws from the bottom up.
        var weight = 0.0, x = 0.0, y = 0.0
        for row in 0..<height {
            for column in 0..<width {
                let alpha = Double(pixels[row * stride + column * 4 + 3]) / 255
                weight += alpha
                x += alpha * (Double(column) + 0.5)
                y += alpha * (Double(height - 1 - row) + 0.5)
            }
        }
        guard weight > 0 else { return .zero }

        // From the centroid back to the centre: the artwork has to move by as
        // much as its axis is out.
        return CGSize(width: (Double(width) / 2 - x / weight) / sourceScale,
                      height: (Double(height) / 2 - y / weight) / sourceScale)
    }

    /// The frame at `angle`, rasterised at `scale` pixels per point.
    ///
    /// The master is already centred on its axis, so turning it about the middle
    /// of the canvas turns it about the hub. The blades stay inside: they sweep
    /// a circle 15.8 points across, well within the 18 of the canvas, so no
    /// frame clips its own corners.
    private static func representation(of master: CGImage, angle: CGFloat,
                                       scale: CGFloat) -> NSBitmapImageRep? {
        let side = Int((pointSize * scale).rounded())
        guard side > 0,
              let context = CGContext(data: nil,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: pointSize / 2, y: pointSize / 2)
        context.rotate(by: angle)
        context.interpolationQuality = .high
        context.draw(master, in: CGRect(x: -pointSize / 2, y: -pointSize / 2,
                                        width: pointSize, height: pointSize))

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
