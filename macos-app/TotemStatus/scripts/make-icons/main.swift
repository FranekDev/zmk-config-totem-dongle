// Renders AppIcon.icns (and optional menu bar previews) from TotemIcon.swift.
// Usage: swiftc -o /tmp/mkicons Sources/TotemStatus/TotemIcon.swift scripts/make-icons/main.swift && /tmp/mkicons <outdir> [previewdir]
import AppKit

func png(_ size: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ rect: CGRect) {
    let s = rect.width
    // macOS icon grid: 824/1024 body with rounded corners
    let body = rect.insetBy(dx: s * 0.0977, dy: s * 0.0977)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(red: 0.16, green: 0.19, blue: 0.23, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor(red: 0.79, green: 0.82, blue: 0.85, alpha: 1).setFill()  // #c9d1d9 from the logo
    TotemIcon.path(in: body.insetBy(dx: body.width * 0.2, dy: body.width * 0.2)).fill()
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(base * scale, appIcon).write(to: iconset.appendingPathComponent(name))
    }
}

if args.count > 2 {
    let dir = URL(fileURLWithPath: args[2])
    let samples: [(String, NSImage)] = [
        ("mac", TotemIcon.statusImage(symbol: "apple.logo", batteries: [(87, false), (64, true)])),
        ("win", TotemIcon.statusImage(symbol: "pc", batteries: [(87, false), (nil, false)])),
        ("off", TotemIcon.statusImage(symbol: nil, dimmed: true)),
    ]
    for (name, img) in samples {
        for (bgName, bg, fg) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black),
                                 ("dark", NSColor(white: 0.15, alpha: 1), NSColor.white)] {
            let scale: CGFloat = 4
            let w = Int(img.size.width * scale) + 24, h = Int(img.size.height * scale) + 24
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bg.setFill(); CGRect(x: 0, y: 0, width: w, height: h).fill()
            let r = CGRect(x: 12, y: 12, width: img.size.width * scale, height: img.size.height * scale)
            // tint template like the menu bar does
            let tinted = NSImage(size: img.size, flipped: false) { rr in
                img.draw(in: rr); fg.set(); rr.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!
                .write(to: dir.appendingPathComponent("bar_\(name)_\(bgName).png"))
        }
    }
}
