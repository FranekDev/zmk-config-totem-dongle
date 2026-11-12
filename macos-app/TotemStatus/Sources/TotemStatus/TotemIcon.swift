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
    static func menuBarImage(height: CGFloat = 15) -> NSImage {
        let w = (height * size.width / size.height).rounded(.up)
        let image = NSImage(size: NSSize(width: w, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full menu bar label as one template image: TOTEM face, optional OS symbol, then each
    /// battery as "87%" followed by a bolt when that half is charging.
    static func statusImage(symbol: String?, batteries: [(level: Int?, charging: Bool)] = [],
                            dimmed: Bool = false) -> NSImage {
        let height: CGFloat = 20
        let faceHeight: CGFloat = 16
        let faceWidth = (faceHeight * size.width / size.height).rounded(.up)
        let gap: CGFloat = 4

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let boltConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)

        enum Part { case image(NSImage, gapBefore: CGFloat), text(String, gapBefore: CGFloat) }
        var parts: [Part] = []
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            parts.append(.image(img, gapBefore: gap))
        }
        for battery in batteries {
            let text: String
            if let level = battery.level, level > 0 { text = "\(level)%" } else { text = "–" }
            parts.append(.text(text, gapBefore: gap + 1))
            if battery.charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(boltConfig) {
                parts.append(.image(bolt, gapBefore: 1))
            }
        }

        var width = faceWidth
        for part in parts {
            switch part {
            case let .image(img, g): width += g + img.size.width
            case let .text(t, g): width += g + (t as NSString).size(withAttributes: attrs).width
            }
        }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            let alpha: CGFloat = dimmed ? 0.45 : 1
            NSColor.black.withAlphaComponent(alpha).setFill()
            var x: CGFloat = 0
            path(in: CGRect(x: x, y: (height - faceHeight) / 2, width: faceWidth, height: faceHeight)).fill()
            x += faceWidth
            for part in parts {
                switch part {
                case let .image(img, g):
                    x += g
                    img.draw(in: CGRect(x: x, y: (height - img.size.height) / 2,
                                        width: img.size.width, height: img.size.height),
                             from: .zero, operation: .sourceOver, fraction: alpha)
                    x += img.size.width
                case let .text(t, g):
                    x += g
                    let sz = (t as NSString).size(withAttributes: attrs)
                    (t as NSString).draw(at: CGPoint(x: x, y: (height - sz.height) / 2), withAttributes: attrs)
                    x += sz.width
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
