import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build")
let iconsetDirectory = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let iconFile = outputDirectory.appendingPathComponent("AppIcon.icns")

let fileManager = FileManager.default
try fileManager.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

let iconEntries: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in iconEntries {
    let image = GlyphAppIconRenderer.makeImage(pixels: entry.pixels)
    let url = iconsetDirectory.appendingPathComponent(entry.name)
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw IconGenerationError.pngEncodingFailed(entry.name)
    }

    try pngData.write(to: url, options: .atomic)
}

if fileManager.fileExists(atPath: iconFile.path) {
    try fileManager.removeItem(at: iconFile)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconsetDirectory.path,
    "-o", iconFile.path
]

try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw IconGenerationError.iconutilFailed(process.terminationStatus)
}

private enum IconGenerationError: Error {
    case pngEncodingFailed(String)
    case iconutilFailed(Int32)
}

private enum GlyphAppIconRenderer {
    static func makeImage(pixels: CGFloat) -> NSImage {
        let size = NSSize(width: pixels, height: pixels)
        let image = NSImage(size: size)

        image.lockFocus()
        defer {
            image.unlockFocus()
        }

        let bounds = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        bounds.fill()

        let shadow = NSShadow()
        shadow.shadowBlurRadius = pixels * 0.035
        shadow.shadowOffset = NSSize(width: 0, height: -pixels * 0.012)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.set()

        let badgeInset = pixels * 0.055
        let badgeRect = bounds.insetBy(dx: badgeInset, dy: badgeInset)
        let radius = pixels * 0.21
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: radius, yRadius: radius)

        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.40, green: 0.46, blue: 0.96, alpha: 1),
                NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.42, alpha: 1)
            ]
        )
        gradient?.draw(in: badge, angle: 90)

        shadow.shadowColor = nil
        shadow.set()
        NSColor.white.setStroke()

        let center = pixels * 0.5
        let leftX = pixels * 0.35
        let rightX = pixels * 0.67
        let topY = pixels * 0.69
        let bottomY = pixels * 0.31
        let lineWidth = max(2, pixels * 0.13)

        drawLine(
            from: NSPoint(x: leftX, y: bottomY),
            to: NSPoint(x: rightX, y: center),
            lineWidth: lineWidth
        )
        drawLine(
            from: NSPoint(x: rightX, y: center),
            to: NSPoint(x: leftX, y: topY),
            lineWidth: lineWidth
        )

        return image
    }

    private static func drawLine(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.stroke()
    }
}
