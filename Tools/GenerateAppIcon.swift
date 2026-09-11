import AppKit

/// A propeller blade described the way a real one is: a centreline that sweeps
/// as it goes out, and a width profile along it. Sampling that and walking up
/// one edge and back down the other gives full control over the silhouette —
/// narrow at the root, belly around two thirds out, rounded tip.
struct Blade {
    var rootRadius: CGFloat = 0.20      // where the blade leaves the hub
    var tipRadius: CGFloat = 0.95
    var rootWidth: CGFloat = 0.10       // half-widths, as arc length
    var bellyWidth: CGFloat = 0.26
    var tipWidth: CGFloat = 0.13
    var sweep: CGFloat = 0.34           // radians the tip leans back

    /// Quadratic blend through root, belly and tip.
    private func halfWidth(_ t: CGFloat) -> CGFloat {
        let u = 1 - t
        return u * u * rootWidth + 2 * u * t * bellyWidth + t * t * tipWidth
    }

    private func centre(_ t: CGFloat) -> (radius: CGFloat, angle: CGFloat) {
        (rootRadius + t * (tipRadius - tipWidth - rootRadius), .pi / 2 + sweep * t)
    }

    func path(rotatedBy rotation: CGFloat) -> CGPath {
        let steps = 96

        /// Centreline point, in Cartesian space.
        func spine(_ t: CGFloat) -> CGPoint {
            let c = centre(t)
            return CGPoint(x: cos(c.angle + rotation) * c.radius,
                           y: sin(c.angle + rotation) * c.radius)
        }

        /// Offset perpendicular to the spine — a true constant-width ribbon.
        /// Offsetting by angle instead would flare the blade near the hub,
        /// where a small radius turns a modest width into a wide arc.
        func edge(_ t: CGFloat, side: CGFloat) -> CGPoint {
            let delta: CGFloat = 0.001
            let a = spine(max(0, t - delta)), b = spine(min(1, t + delta))
            let length = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
            let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
            let p = spine(t)
            return CGPoint(x: p.x + normal.x * halfWidth(t) * side,
                           y: p.y + normal.y * halfWidth(t) * side)
        }

        let path = CGMutablePath()
        path.move(to: edge(0, side: -1))
        for i in 1...steps { path.addLine(to: edge(CGFloat(i) / CGFloat(steps), side: -1)) }

        let tip = spine(1)
        let from = edge(1, side: -1), to = edge(1, side: 1)
        path.addArc(center: tip, radius: halfWidth(1),
                    startAngle: atan2(from.y - tip.y, from.x - tip.x),
                    endAngle: atan2(to.y - tip.y, to.x - tip.x),
                    clockwise: false)
        for i in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: edge(CGFloat(i) / CGFloat(steps), side: 1))
        }
        path.closeSubpath()
        return path
    }
}

func fillRotor(in ctx: CGContext, diameter: CGFloat, centre c: CGPoint,
               blades: Int, blade: Blade, hub: CGFloat) {
    let scale = diameter / 2
    let place = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: scale, y: scale)
    for i in 0..<blades {
        let angle = CGFloat(i) * (2 * .pi / CGFloat(blades))
        ctx.addPath(blade.path(rotatedBy: angle).copy(using: [place])!)
        ctx.fillPath()
    }
    ctx.addEllipse(in: CGRect(x: c.x - scale * hub, y: c.y - scale * hub,
                              width: scale * hub * 2, height: scale * hub * 2))
    ctx.fillPath()
}

func drawIcon(size: CGFloat, blades: Int, blade: Blade, hub: CGFloat, diameter: CGFloat) -> CGImage {
    let s = size / 1024
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(red: 0.26, green: 0.29, blue: 0.34, alpha: 1),
                                       CGColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    fillRotor(in: ctx, diameter: diameter, centre: CGPoint(x: 512, y: 512),
              blades: blades, blade: blade, hub: hub)
    return ctx.makeImage()!
}

// The mark: four swept blades on a small hub, matching the rotor in the menu
// bar. Widths are on the generous side so it still reads at 16 points.
let bladeCount = 4
let blade = Blade(rootWidth: 0.095, bellyWidth: 0.20, tipWidth: 0.145, sweep: 0.36)
let hub: CGFloat = 0.22
let rotorDiameter: CGFloat = 600

let directory = CommandLine.arguments[1]
let slots: [(size: Int, scale: Int, pixels: Int)] = [
    (16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64), (128, 1, 128),
    (128, 2, 256), (256, 1, 256), (256, 2, 512), (512, 1, 512), (512, 2, 1024),
]

var entries: [String] = []
var written = Set<Int>()
for slot in slots {
    let name = "icon_\(slot.pixels).png"
    if written.insert(slot.pixels).inserted {
        // Drawn at 1024 and resampled: the blade outline is a fine polyline, and
        // rasterising it directly at 16 points would lose its shape.
        let full = drawIcon(size: 1024, blades: bladeCount, blade: blade,
                            hub: hub, diameter: rotorDiameter)
        let ctx = CGContext(data: nil, width: slot.pixels, height: slot.pixels,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: slot.pixels, height: slot.pixels))
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.size)x\(slot.size)"
        }
    """)
}

let json = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try! json.write(to: URL(fileURLWithPath: directory).appendingPathComponent("Contents.json"),
                atomically: true, encoding: .utf8)
print("ecrit \(written.count) PNG + Contents.json")
