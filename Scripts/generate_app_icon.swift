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

        let isSmallIcon = pixels <= 64
        let shadow = NSShadow()
        shadow.shadowBlurRadius = isSmallIcon ? 0 : pixels * 0.035
        shadow.shadowOffset = isSmallIcon ? .zero : NSSize(width: 0, height: -pixels * 0.012)
        shadow.shadowColor = isSmallIcon ? nil : NSColor.black.withAlphaComponent(0.18)
        shadow.set()

        let badgeInset = pixels * 0.055
        let badgeRect = bounds.insetBy(dx: badgeInset, dy: badgeInset)
        let radius = pixels * 0.21
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: radius, yRadius: radius)

        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.20, alpha: 1),
                NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)
            ]
        )
        gradient?.draw(in: badge, angle: 90)

        if !isSmallIcon {
            NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
            badge.lineWidth = max(1, pixels * 0.008)
            badge.stroke()
        }

        shadow.shadowColor = nil
        shadow.set()
        shadow.shadowBlurRadius = isSmallIcon ? 0 : pixels * 0.025
        shadow.shadowOffset = isSmallIcon ? .zero : NSSize(width: 0, height: -pixels * 0.006)
        shadow.shadowColor = isSmallIcon ? nil : NSColor.black.withAlphaComponent(0.22)
        shadow.set()

        let centerY = pixels * 0.5
        let barWidth = max(isSmallIcon ? 1.5 : 2, pixels * 0.083)
        let bars: [(x: CGFloat, height: CGFloat, color: NSColor)] = if isSmallIcon {
            [
                (0.21, 0.26, NSColor(calibratedWhite: 1, alpha: 0.90)),
                (0.36, 0.47, NSColor(calibratedWhite: 1, alpha: 0.98)),
                (0.50, 0.59, NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.94, alpha: 1)),
                (0.64, 0.41, NSColor(calibratedWhite: 1, alpha: 0.98)),
                (0.79, 0.23, NSColor(calibratedWhite: 1, alpha: 0.90))
            ]
        } else {
            [
                (0.21, 0.26, NSColor(calibratedWhite: 1, alpha: 0.90)),
                (0.36, 0.47, NSColor(calibratedWhite: 1, alpha: 0.98)),
                (0.50, 0.59, NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.94, alpha: 1)),
                (0.64, 0.41, NSColor(calibratedWhite: 1, alpha: 0.98)),
                (0.79, 0.23, NSColor(calibratedWhite: 1, alpha: 0.90))
            ]
        }

        for bar in bars {
            drawRoundedBar(
                centerX: pixels * bar.x,
                centerY: centerY,
                width: barWidth,
                height: max(barWidth, pixels * bar.height),
                color: bar.color
            )
        }

        return image
    }

    private static func drawRoundedBar(
        centerX: CGFloat,
        centerY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        color: NSColor
    ) {
        let rect = NSRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
        color.setFill()
        path.fill()
    }
}
