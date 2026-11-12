import AppKit

/// The "face" glyph from the TOTEM logo (github.com/GEIGEIGEIST/TOTEM, docs/images/TOTEM_logo_dark.svg):
/// two ring eyes, two brows, a nose and a mouth. Geometry in the SVG's own units (y down).
enum TotemIcon {
    static let size = CGSize(width: 371.21, height: 329.67)

    /// Builds the glyph path in SVG coordinates, scaled into `rect` (AppKit, y up).
    static func path(in rect: CGRect) -> NSBezierPath {
        let s = min(rect.width / size.width, rect.height / size.height)
        let ox = rect.minX + (rect.width - size.width * s) / 2
        let oy = rect.minY + (rect.height - size.height * s) / 2
        // SVG y-down -> AppKit y-up
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (size.height - y - h) * s, width: w * s, height: h * s)
        }

        let p = NSBezierPath()
        p.windingRule = .evenOdd

        // Eyes: rings, outer r 68.57, inner r 26.67
        for cx in [70.43, 300.76] {
            let cy = 125.94
            p.appendOval(in: r(cx - 68.57, cy - 68.57, 137.14, 137.14))
            p.appendOval(in: r(cx - 26.67, cy - 26.67, 53.34, 53.34))
        }
        let rad = 20.94 * s
        // Brows
        p.appendRoundedRect(r(0, 0, 140.87, 41.9), xRadius: rad, yRadius: rad)
        p.appendRoundedRect(r(230.33, 0, 140.88, 41.9), xRadius: rad, yRadius: rad)
        // Nose
        p.appendRoundedRect(r(164.66, 100.01, 41.88, 161.32), xRadius: rad, yRadius: rad)
        // Mouth
        p.appendRoundedRect(r(115.17, 287.77, 140.86, 41.9), xRadius: rad, yRadius: rad)
        return p
    }

    /// Template image for the menu bar (adapts to light/dark menu bar automatically).
    /// `dimmed` draws it semi-transparent, used while no dongle is connected.
    static func menuBarImage(height: CGFloat = 16, dimmed: Bool = false) -> NSImage {
        let w = (height * size.width / size.height).rounded(.up)
        let image = NSImage(size: NSSize(width: w, height: height), flipped: false) { rect in
            NSColor.black.withAlphaComponent(dimmed ? 0.4 : 1).setFill()
            path(in: rect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
