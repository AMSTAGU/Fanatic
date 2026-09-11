//
//  RotorGlyph.swift
//  Fan
//
//  Draws the rotor glyph, tinted for the menu bar. Rendering is rare — once per
//  appearance change — so the spinning layer only ever reuses a finished bitmap.
//

import AppKit

enum RotorGlyph {

    static let symbolName = "fanblades.fill"

    /// A tinted rotor, `pointSize` square, rendered at `scale` pixels per point.
    ///
    /// The symbol's artwork is centred within its own box, so aspect-fitting it
    /// into a square canvas puts its axis of rotation on the canvas centre —
    /// which is what keeps the blades from wobbling as the layer turns.
    static func image(color: NSColor, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: "Ventilateur")?
            .withSymbolConfiguration(configuration)
        else { return nil }

        let side = Int((pointSize * scale).rounded())
        guard side > 0,
              let context = CGContext(data: nil,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let canvas = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        let fitted = symbol.size.fitted(in: canvas.size)
        let frame = CGRect(x: canvas.midX - fitted.width / 2,
                           y: canvas.midY - fitted.height / 2,
                           width: fitted.width, height: fitted.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        symbol.draw(in: frame)
        color.set()
        canvas.fill(using: .sourceAtop)          // tint the template in place
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
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
