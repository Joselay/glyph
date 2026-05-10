import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let outputDirectory = URL(fileURLWithPath: arguments.first ?? "build")
let sourceImageURL = URL(fileURLWithPath: arguments.dropFirst().first ?? "Resources/AppIconSource.png")
let iconsetDirectory = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let iconFile = outputDirectory.appendingPathComponent("AppIcon.icns")

let fileManager = FileManager.default
if fileManager.fileExists(atPath: iconsetDirectory.path) {
    try fileManager.removeItem(at: iconsetDirectory)
}
try fileManager.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceImageURL) else {
    throw IconGenerationError.sourceImageNotFound(sourceImageURL.path)
}

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
    let pngData = IconSourceRenderer.makePNGData(from: sourceImage, pixels: Int(entry.pixels))
    let url = iconsetDirectory.appendingPathComponent(entry.name)
    guard let pngData else {
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
    case sourceImageNotFound(String)
    case pngEncodingFailed(String)
    case iconutilFailed(Int32)
}

private enum IconSourceRenderer {
    static func makePNGData(from sourceImage: NSImage, pixels: Int) -> Data? {
        let size = NSSize(width: pixels, height: pixels)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = size
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer {
            NSGraphicsContext.current = previousContext
        }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: sourceImage.size),
            operation: .sourceOver,
            fraction: 1
        )

        return bitmap.representation(using: .png, properties: [:])
    }
}
