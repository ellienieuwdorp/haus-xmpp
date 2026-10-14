import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures of the sample conversations, drawn here with Core Graphics so no image ships and nothing is fetched:
/// the contacts' avatars (illustrations, not people's photos), the photo in Alex's chat and its café link's thumbnail.
/// Every drawing works in a y-down canvas of its own pixel size; the same code draws them on the iPhone and the Mac.
enum DemoArt {
    // MARK: Avatars

    /// 512 px avatars, PNG, as a contact would publish one.
    enum Avatar { case alex, maya, sam, notes, own }

    static func avatarPNG(_ avatar: Avatar) -> Data? {
        png(width: 512, height: 512) { canvas in
            switch avatar {
            case .alex:
                portrait(canvas, background: [rgb(1.00, 0.72, 0.58), rgb(0.96, 0.52, 0.47)], skin: rgb(0.87, 0.63, 0.47),
                         hair: rgb(0.23, 0.15, 0.13), sweater: rgb(0.18, 0.53, 0.55), curls: true)
            case .own:
                portrait(canvas, background: [rgb(0.73, 0.71, 0.96), rgb(0.52, 0.53, 0.88)], skin: rgb(0.96, 0.80, 0.68),
                         hair: rgb(0.45, 0.27, 0.17), sweater: rgb(0.95, 0.69, 0.27), curls: false)
            case .maya: valley(canvas)
            case .sam: cat(canvas)
            case .notes: note(canvas)
            }
        }
    }

    /// A friendly head-and-shoulders figure: soft background, sweater, closed smiling eyes and a little blush.
    private static func portrait(_ c: CGContext, background: [CGColor], skin: CGColor, hair: CGColor, sweater: CGColor, curls: Bool) {
        linear(c, background, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 512, y: 512))
        radial(c, [rgba(1, 1, 1, 0.28), rgba(1, 1, 1, 0)], center: CGPoint(x: 150, y: 120), radius: 320)
        if !curls {
            // Long hair falls behind the shoulders.
            c.setFillColor(hair)
            c.addPath(rounded(CGRect(x: 130, y: 120, width: 252, height: 330), radius: 120))
            c.fillPath()
        }
        // Shoulders.
        c.setFillColor(sweater)
        let shoulders = CGMutablePath()
        shoulders.move(to: CGPoint(x: 56, y: 512))
        shoulders.addCurve(to: CGPoint(x: 256, y: 372), control1: CGPoint(x: 60, y: 420), control2: CGPoint(x: 150, y: 372))
        shoulders.addCurve(to: CGPoint(x: 456, y: 512), control1: CGPoint(x: 362, y: 372), control2: CGPoint(x: 452, y: 420))
        shoulders.closeSubpath()
        c.addPath(shoulders); c.fillPath()
        // Collar shadow and neck.
        c.setFillColor(shade(skin, 0.86))
        c.addPath(rounded(CGRect(x: 216, y: 300, width: 80, height: 100), radius: 30)); c.fillPath()
        c.setFillColor(shade(sweater, 0.82))
        c.fillEllipse(in: CGRect(x: 200, y: 372, width: 112, height: 30))
        c.setFillColor(shade(skin, 0.86))
        c.fillEllipse(in: CGRect(x: 214, y: 360, width: 84, height: 28))
        // Ears and head.
        c.setFillColor(skin)
        c.fillEllipse(in: CGRect(x: 150, y: 222, width: 40, height: 56))
        c.fillEllipse(in: CGRect(x: 322, y: 222, width: 40, height: 56))
        c.fillEllipse(in: CGRect(x: 168, y: 130, width: 176, height: 206))
        // Hair on top.
        c.setFillColor(hair)
        if curls {
            for (x, y, r) in [(176.0, 196.0, 30.0), (186, 156, 34), (220, 128, 36), (262, 118, 38), (302, 132, 36), (332, 162, 32), (340, 200, 26),
                              (240, 150, 30), (282, 150, 30)] {
                c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        } else {
            let fringe = CGMutablePath()
            fringe.move(to: CGPoint(x: 164, y: 240))
            fringe.addCurve(to: CGPoint(x: 256, y: 112), control1: CGPoint(x: 156, y: 160), control2: CGPoint(x: 196, y: 112))
            fringe.addCurve(to: CGPoint(x: 350, y: 250), control1: CGPoint(x: 322, y: 112), control2: CGPoint(x: 362, y: 170))
            fringe.addCurve(to: CGPoint(x: 236, y: 172), control1: CGPoint(x: 310, y: 210), control2: CGPoint(x: 268, y: 196))
            fringe.addCurve(to: CGPoint(x: 164, y: 240), control1: CGPoint(x: 206, y: 196), control2: CGPoint(x: 178, y: 214))
            c.addPath(fringe); c.fillPath()
        }
        // Blush, closed eyes and a smile.
        c.setFillColor(rgba(0.95, 0.42, 0.42, 0.28))
        c.fillEllipse(in: CGRect(x: 192, y: 262, width: 40, height: 24))
        c.fillEllipse(in: CGRect(x: 280, y: 262, width: 40, height: 24))
        c.setStrokeColor(shade(hair, 0.9)); c.setLineWidth(7); c.setLineCap(.round)
        for x in [222.0, 290.0] {
            c.move(to: CGPoint(x: x - 14, y: 246))
            c.addQuadCurve(to: CGPoint(x: x + 14, y: 246), control: CGPoint(x: x, y: 258))
        }
        c.strokePath()
        c.setStrokeColor(shade(skin, 0.55)); c.setLineWidth(6)
        c.move(to: CGPoint(x: 238, y: 292)); c.addQuadCurve(to: CGPoint(x: 274, y: 292), control: CGPoint(x: 256, y: 306))
        c.strokePath()
    }

    /// Hills at dusk with a winding path: someone who takes the scenic route.
    private static func valley(_ c: CGContext) {
        linear(c, [rgb(0.99, 0.80, 0.60), rgb(0.98, 0.62, 0.55), rgb(0.62, 0.50, 0.75)], from: CGPoint(x: 0, y: 340), to: CGPoint(x: 0, y: 0))
        radial(c, [rgba(1, 0.95, 0.80, 1), rgba(1, 0.90, 0.70, 0)], center: CGPoint(x: 330, y: 176), radius: 150)
        c.setFillColor(rgb(1, 0.95, 0.82)); c.fillEllipse(in: CGRect(x: 290, y: 136, width: 80, height: 80))
        hills(c, base: 512, color: rgb(0.47, 0.42, 0.66), points: [(0, 300), (110, 236), (210, 290), (330, 220), (440, 280), (512, 250)])
        hills(c, base: 512, color: rgb(0.33, 0.46, 0.58), points: [(0, 350), (140, 300), (260, 352), (380, 300), (512, 340)])
        hills(c, base: 512, color: rgb(0.20, 0.38, 0.40), points: [(0, 410), (120, 380), (250, 420), (390, 370), (512, 400)])
        c.setStrokeColor(rgba(1, 0.92, 0.78, 0.9)); c.setLineWidth(14); c.setLineCap(.round)
        c.move(to: CGPoint(x: 190, y: 530))
        c.addCurve(to: CGPoint(x: 290, y: 400), control1: CGPoint(x: 340, y: 490), control2: CGPoint(x: 170, y: 440))
        c.strokePath()
    }

    /// An orange cat on a cool blue.
    private static func cat(_ c: CGContext) {
        linear(c, [rgb(0.62, 0.82, 0.96), rgb(0.42, 0.62, 0.90)], from: .zero, to: CGPoint(x: 512, y: 512))
        let fur = rgb(0.96, 0.62, 0.30), light = rgb(1, 0.90, 0.78), pink = rgb(0.96, 0.60, 0.62)
        // Ears.
        for (tip, left, right) in [(CGPoint(x: 150, y: 96), CGPoint(x: 120, y: 250), CGPoint(x: 250, y: 170)),
                                   (CGPoint(x: 362, y: 96), CGPoint(x: 262, y: 170), CGPoint(x: 392, y: 250))] {
            c.setFillColor(fur)
            c.move(to: tip); c.addLine(to: right); c.addLine(to: left); c.closePath(); c.fillPath()
            c.setFillColor(pink)
            let inset = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
            func toward(_ p: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: p.x + (inset.x - p.x) * t, y: p.y + (inset.y - p.y) * t) }
            c.move(to: toward(tip, 0.25)); c.addLine(to: toward(right, 0.35)); c.addLine(to: toward(left, 0.35)); c.closePath(); c.fillPath()
        }
        // Head, muzzle, stripes.
        c.setFillColor(fur); c.fillEllipse(in: CGRect(x: 96, y: 140, width: 320, height: 290))
        c.setFillColor(shade(fur, 0.84))
        for (x, w) in [(236.0, 14.0), (212, 10), (282, 10)] {
            c.addPath(rounded(CGRect(x: x, y: 146, width: w, height: 62), radius: w / 2)); c.fillPath()
        }
        c.setFillColor(light)
        c.fillEllipse(in: CGRect(x: 176, y: 300, width: 90, height: 84))
        c.fillEllipse(in: CGRect(x: 246, y: 300, width: 90, height: 84))
        // Eyes with a glint.
        for x in [196.0, 316.0] {
            c.setFillColor(rgb(0.16, 0.20, 0.22)); c.fillEllipse(in: CGRect(x: x - 22, y: 240, width: 44, height: 54))
            c.setFillColor(rgb(1, 1, 1)); c.fillEllipse(in: CGRect(x: x - 8, y: 248, width: 15, height: 15))
        }
        // Nose, mouth and whiskers.
        c.setFillColor(pink)
        c.move(to: CGPoint(x: 236, y: 304)); c.addLine(to: CGPoint(x: 276, y: 304)); c.addLine(to: CGPoint(x: 256, y: 326)); c.closePath(); c.fillPath()
        c.setStrokeColor(rgb(0.45, 0.28, 0.20)); c.setLineWidth(5); c.setLineCap(.round)
        c.move(to: CGPoint(x: 256, y: 326)); c.addQuadCurve(to: CGPoint(x: 226, y: 344), control: CGPoint(x: 246, y: 346))
        c.move(to: CGPoint(x: 256, y: 326)); c.addQuadCurve(to: CGPoint(x: 286, y: 344), control: CGPoint(x: 266, y: 346))
        c.strokePath()
        c.setStrokeColor(rgba(1, 1, 1, 0.85)); c.setLineWidth(4)
        for (y, d) in [(326.0, -10.0), (342, 4)] {
            c.move(to: CGPoint(x: 186, y: y)); c.addLine(to: CGPoint(x: 92, y: y + d))
            c.move(to: CGPoint(x: 326, y: y)); c.addLine(to: CGPoint(x: 420, y: y + d))
        }
        c.strokePath()
    }

    /// A tilted note card with a star: the chat with yourself.
    private static func note(_ c: CGContext) {
        linear(c, [rgb(1, 0.88, 0.50), rgb(0.98, 0.70, 0.32)], from: .zero, to: CGPoint(x: 512, y: 512))
        c.saveGState()
        c.translateBy(x: 256, y: 262); c.rotate(by: -0.12)
        c.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgba(0.55, 0.30, 0, 0.30))
        c.setFillColor(rgb(1, 0.99, 0.96))
        c.addPath(rounded(CGRect(x: -140, y: -170, width: 280, height: 330), radius: 34)); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(rgb(0.90, 0.86, 0.80))
        for (index, width) in [180.0, 210, 150].enumerated() {
            c.addPath(rounded(CGRect(x: -100, y: 30 + Double(index) * 38, width: width, height: 16), radius: 8)); c.fillPath()
        }
        c.setFillColor(rgb(0.98, 0.66, 0.16))
        c.addPath(star(center: CGPoint(x: 0, y: -66), outer: 74, inner: 32)); c.fillPath()
        c.restoreGState()
    }

    // MARK: The photo and the café thumbnail

    /// Alex's photo, 1200 × 600: a lake at sunrise with a boathouse on a jetty.
    static func lakePhotoJPEG() -> Data? {
        jpeg(width: 1200, height: 600, quality: 0.85) { c in
            c.translateBy(x: 0, y: -120) // drawn for an 800 px canvas: the top of the sky and the near water are cropped
            let horizon = 470.0
            linear(c, [rgb(0.42, 0.55, 0.80), rgb(0.70, 0.64, 0.84), rgb(0.97, 0.72, 0.62), rgb(1, 0.86, 0.64)],
                   locations: [0, 0.45, 0.82, 1], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: horizon))
            radial(c, [rgba(1, 0.92, 0.74, 0.9), rgba(1, 0.82, 0.62, 0)], center: CGPoint(x: 760, y: 330), radius: 360)
            // Soft clouds.
            for (x, y, w, h, a) in [(110.0, 168.0, 340.0, 30.0, 0.26), (250, 204, 220, 20, 0.18), (840, 140, 280, 26, 0.24), (930, 228, 200, 18, 0.26)] {
                c.setFillColor(rgba(1, 0.94, 0.93, a))
                c.addPath(rounded(CGRect(x: x, y: y, width: w, height: h), radius: h / 2)); c.fillPath()
                c.addPath(rounded(CGRect(x: x + w * 0.2, y: y - h * 0.55, width: w * 0.45, height: h), radius: h / 2)); c.fillPath()
            }
            c.setFillColor(rgb(1, 0.97, 0.88)); c.fillEllipse(in: CGRect(x: 714, y: 284, width: 92, height: 92))
            // Distant ranges, hazier the farther they are.
            let far: [(Double, Double)] = [(0, 380), (140, 330), (260, 372), (420, 316), (560, 384), (680, 360), (860, 398), (1000, 338), (1200, 372)]
            let mid: [(Double, Double)] = [(0, 424), (180, 396), (360, 438), (540, 410), (760, 446), (980, 404), (1200, 430)]
            hills(c, base: horizon, color: rgba(0.66, 0.58, 0.78, 0.9), points: far)
            hills(c, base: horizon, color: rgba(0.47, 0.43, 0.65, 0.95), points: mid)
            // Water: the sky's colours, deepening towards the shore.
            linear(c, [rgb(0.97, 0.78, 0.66), rgb(0.64, 0.59, 0.79), rgb(0.27, 0.31, 0.52)], from: CGPoint(x: 0, y: horizon), to: CGPoint(x: 0, y: 800),
                   clip: CGRect(x: 0, y: horizon, width: 1200, height: 330))
            // Pines on the left shore, and their reflection.
            let pines = { (alpha: Double) in
                c.setFillColor(rgba(0.20, 0.25, 0.38, alpha))
                c.fill(CGRect(x: 0, y: horizon - 14, width: 470, height: 16))
                var x = -10.0
                for index in 0..<40 {
                    let height = 46.0 + Double((index * 37) % 50)
                    c.move(to: CGPoint(x: x, y: horizon + 2)); c.addLine(to: CGPoint(x: x + 13, y: horizon - height)); c.addLine(to: CGPoint(x: x + 26, y: horizon + 2))
                    c.closePath(); c.fillPath()
                    x += 14 + Double((index * 13) % 9)
                    if x > 450 { break }
                }
            }
            c.saveGState()
            c.translateBy(x: 0, y: 1.8 * horizon + 4); c.scaleBy(x: 1, y: -0.8)
            hills(c, base: horizon, color: rgba(0.47, 0.43, 0.65, 0.22), points: mid)
            pines(0.28)
            c.restoreGState()
            pines(1)
            // The sun's glitter path and a few ripples.
            c.setLineCap(.round)
            var y = horizon + 8
            for row in 0..<30 {
                let width = 70.0 + Double((row * 47) % 90) + Double(row) * 2
                let offset = Double((row * 31) % 36) - 18
                c.setStrokeColor(rgba(1, 0.94, 0.80, max(0.08, 0.8 - Double(row) * 0.026))); c.setLineWidth(3 + Double(row) * 0.18)
                c.move(to: CGPoint(x: 760 + offset - width / 2, y: y)); c.addLine(to: CGPoint(x: 760 + offset + width / 2, y: y))
                c.strokePath()
                y += 7 + Double(row) * 0.55
                if y > 790 { break }
            }
            c.setStrokeColor(rgba(1, 1, 1, 0.14)); c.setLineWidth(2)
            for (rx, ry, rw) in [(90.0, 560.0, 220.0), (380, 612, 150), (980, 590, 160), (200, 700, 260), (900, 730, 210)] {
                c.move(to: CGPoint(x: rx, y: ry)); c.addLine(to: CGPoint(x: rx + rw, y: ry)); c.strokePath()
            }
            // The boathouse, its lit windows and the jetty.
            let wood = rgb(0.24, 0.19, 0.27)
            c.setFillColor(wood)
            c.fill(CGRect(x: 900, y: horizon - 6, width: 300, height: 14))
            c.fill(CGRect(x: 960, y: 398, width: 150, height: 80))
            c.move(to: CGPoint(x: 944, y: 404)); c.addLine(to: CGPoint(x: 1035, y: 350)); c.addLine(to: CGPoint(x: 1126, y: 404)); c.closePath(); c.fillPath()
            c.setFillColor(rgb(1, 0.82, 0.48)); c.fill(CGRect(x: 1000, y: 420, width: 26, height: 22))
            c.fill(CGRect(x: 1046, y: 420, width: 26, height: 22))
            c.setFillColor(wood); c.fill(CGRect(x: 800, y: horizon + 6, width: 170, height: 9))
            for post in stride(from: 810.0, through: 960, by: 37) { c.fill(CGRect(x: post, y: horizon + 10, width: 6, height: 20)) }
            c.setFillColor(rgba(0.24, 0.19, 0.27, 0.25)); c.fill(CGRect(x: 960, y: horizon + 10, width: 150, height: 60))
            c.setFillColor(rgba(1, 0.82, 0.48, 0.30))
            c.fill(CGRect(x: 1000, y: horizon + 36, width: 26, height: 14)); c.fill(CGRect(x: 1046, y: horizon + 36, width: 26, height: 14))
            // Two birds.
            c.setStrokeColor(rgba(0.25, 0.22, 0.33, 0.8)); c.setLineWidth(3.5)
            for (bx, by, s) in [(520.0, 190.0, 1.0), (566, 214, 0.75)] {
                c.move(to: CGPoint(x: bx - 16 * s, y: by - 6 * s)); c.addQuadCurve(to: CGPoint(x: bx, y: by), control: CGPoint(x: bx - 8 * s, y: by - 10 * s))
                c.addQuadCurve(to: CGPoint(x: bx + 16 * s, y: by - 6 * s), control: CGPoint(x: bx + 8 * s, y: by - 10 * s))
                c.strokePath()
            }
            // Reeds in the near corner: tapered blades.
            c.setFillColor(rgb(0.15, 0.18, 0.28))
            for index in 0..<11 {
                let base = 10.0 + Double(index) * 17, lean = Double((index * 7) % 5) * 14 - 28, top = 610 + Double((index * 23) % 90)
                c.move(to: CGPoint(x: base - 5, y: 800))
                c.addQuadCurve(to: CGPoint(x: base + lean, y: top), control: CGPoint(x: base - 4, y: (800 + top) / 2))
                c.addQuadCurve(to: CGPoint(x: base + 5, y: 800), control: CGPoint(x: base + 6, y: (800 + top) / 2))
                c.closePath(); c.fillPath()
            }
            // A light vignette.
            radial(c, [rgba(0, 0, 0, 0), rgba(0.08, 0.06, 0.16, 0.28)], center: CGPoint(x: 600, y: 400), radius: 820, startRadius: 420)
        }
    }

    /// The café link's thumbnail, 240 × 240 (below a large card's width, so it shows small): a cup of coffee.
    static func cafeThumbnailJPEG() -> Data? {
        jpeg(width: 240, height: 240, quality: 0.85) { c in
            linear(c, [rgb(0.99, 0.91, 0.80), rgb(0.95, 0.78, 0.62)], from: .zero, to: CGPoint(x: 240, y: 240))
            c.setFillColor(rgba(0.55, 0.30, 0.18, 0.18)); c.fillEllipse(in: CGRect(x: 40, y: 168, width: 170, height: 40))
            c.setFillColor(rgb(1, 0.98, 0.95)); c.fillEllipse(in: CGRect(x: 36, y: 158, width: 168, height: 40))
            c.setStrokeColor(rgb(0.80, 0.42, 0.30)); c.setLineWidth(12)
            c.strokeEllipse(in: CGRect(x: 150, y: 104, width: 46, height: 46))
            c.setFillColor(rgb(0.80, 0.42, 0.30))
            let cup = CGMutablePath()
            cup.move(to: CGPoint(x: 62, y: 96)); cup.addLine(to: CGPoint(x: 178, y: 96))
            cup.addCurve(to: CGPoint(x: 120, y: 182), control1: CGPoint(x: 176, y: 160), control2: CGPoint(x: 160, y: 182))
            cup.addCurve(to: CGPoint(x: 62, y: 96), control1: CGPoint(x: 80, y: 182), control2: CGPoint(x: 64, y: 160))
            c.addPath(cup); c.fillPath()
            c.setFillColor(rgb(0.86, 0.52, 0.38)); c.fillEllipse(in: CGRect(x: 62, y: 86, width: 116, height: 22))
            c.setFillColor(rgb(0.42, 0.24, 0.15)); c.fillEllipse(in: CGRect(x: 70, y: 89, width: 100, height: 15))
            c.setStrokeColor(rgba(1, 1, 1, 0.85)); c.setLineWidth(6); c.setLineCap(.round)
            for x in [100.0, 136.0] {
                c.move(to: CGPoint(x: x, y: 74))
                c.addCurve(to: CGPoint(x: x + 2, y: 26), control1: CGPoint(x: x - 16, y: 58), control2: CGPoint(x: x + 16, y: 44))
            }
            c.strokePath()
        }
    }

    // MARK: Drawing helpers

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    private static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// The colour darkened (factor below 1) or lightened (above 1).
    private static func shade(_ color: CGColor, _ factor: Double) -> CGColor {
        let parts = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return rgba(min(1, parts[0] * factor), min(1, parts[1] * factor), min(1, parts[2] * factor), parts.count > 3 ? parts[3] : 1)
    }

    private static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func star(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for index in 0..<10 {
            let angle = -Double.pi / 2 + Double(index) * .pi / 5
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A smooth ridge through `points` filled down to `base`.
    private static func hills(_ c: CGContext, base: Double, color: CGColor, points: [(Double, Double)]) {
        guard let first = points.first, let last = points.last else { return }
        c.setFillColor(color)
        c.move(to: CGPoint(x: first.0, y: base))
        c.addLine(to: CGPoint(x: first.0, y: first.1))
        for (previous, next) in zip(points, points.dropFirst()) {
            let middle = (previous.0 + next.0) / 2
            c.addCurve(to: CGPoint(x: next.0, y: next.1), control1: CGPoint(x: middle, y: previous.1), control2: CGPoint(x: middle, y: next.1))
        }
        c.addLine(to: CGPoint(x: last.0, y: base))
        c.closePath()
        c.fillPath()
    }

    private static func linear(_ c: CGContext, _ colors: [CGColor], locations: [CGFloat]? = nil, from start: CGPoint, to end: CGPoint, clip: CGRect? = nil) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations) else { return }
        c.saveGState()
        if let clip { c.clip(to: clip) }
        c.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    private static func radial(_ c: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat, startRadius: CGFloat = 0) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else { return }
        c.drawRadialGradient(gradient, startCenter: center, startRadius: startRadius, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    }

    /// An sRGB bitmap with a y-down coordinate system, like a view's.
    private static func render(width: Int, height: Int, opaque: Bool, _ body: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        body(context)
        return context.makeImage()
    }

    private static func jpeg(width: Int, height: Int, quality: Double, _ body: (CGContext) -> Void) -> Data? {
        render(width: width, height: height, opaque: true, body).flatMap { LinkPreviewImaging.encode($0, type: .jpeg, quality: quality) }
    }

    private static func png(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data? {
        render(width: width, height: height, opaque: true, body).flatMap { LinkPreviewImaging.encode($0, type: .png, quality: 1) }
    }
}
