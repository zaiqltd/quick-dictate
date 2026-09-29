import AppKit
import Foundation

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let image = NSImage(size: NSSize(width: px, height: px))
        image.lockFocus()
        let unit = CGFloat(px) / 1024
        let rect = NSRect(x: 50 * unit, y: 50 * unit, width: 924 * unit, height: 924 * unit)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 210 * unit, yRadius: 210 * unit)
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.14, alpha: 1).setFill()
        shape.fill()
        NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.66, alpha: 1).setFill()
        for (i, height) in [200.0, 390.0, 550.0, 320.0, 180.0].enumerated() {
            let bar = NSRect(x: (260 + CGFloat(i) * 104) * unit, y: (512 - height / 2) * unit, width: 64 * unit, height: height * unit)
            NSBezierPath(roundedRect: bar, xRadius: 32 * unit, yRadius: 32 * unit).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
