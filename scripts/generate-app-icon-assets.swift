import AppKit
import Foundation

struct Slot {
    let pixels: Int
    let filename: String
    let size: String
    let scale: String
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fputs("usage: generate-app-icon-assets.swift <source-png> <output-dir> <asset-name>\n", stderr)
    exit(64)
}

let sourcePath = arguments[1]
let outputDirectory = URL(fileURLWithPath: arguments[2])
let assetName = arguments[3]
let catalogDirectory = outputDirectory.appendingPathComponent("Assets.xcassets", isDirectory: true)
let appIconSetDirectory = catalogDirectory.appendingPathComponent("\(assetName).appiconset", isDirectory: true)

guard let image = NSImage(contentsOfFile: sourcePath) else {
    fputs("failed to load source image: \(sourcePath)\n", stderr)
    exit(1)
}

let sourceWidth = Int(image.size.width)
let sourceHeight = Int(image.size.height)
guard sourceWidth == sourceHeight else {
    fputs("source image must be square: \(sourcePath)\n", stderr)
    exit(1)
}

try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: appIconSetDirectory, withIntermediateDirectories: true)

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("failed to allocate bitmap\n", stderr)
        exit(1)
    }
    return bitmap
}

let normalized = makeBitmap(width: sourceWidth, height: sourceHeight)
NSGraphicsContext.saveGraphicsState()
guard let normalizedContext = NSGraphicsContext(bitmapImageRep: normalized) else {
    fputs("failed to create graphics context\n", stderr)
    exit(1)
}
normalizedContext.imageInterpolation = .high
NSGraphicsContext.current = normalizedContext
image.draw(
    in: NSRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
    from: .zero,
    operation: .copy,
    fraction: 1.0
)
NSGraphicsContext.restoreGraphicsState()

guard let bitmapData = normalized.bitmapData else {
    fputs("failed to access source bitmap data\n", stderr)
    exit(1)
}

func dominantOpaqueColor(in bitmap: NSBitmapImageRep, data: UnsafeMutablePointer<UInt8>) -> (UInt8, UInt8, UInt8) {
    var counts: [Int: Int] = [:]
    let step = max(bitmap.pixelsWide / 128, 1)
    let bytesPerRow = bitmap.bytesPerRow

    for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
            let offset = y * bytesPerRow + x * 4
            guard data[offset + 3] > 250 else {
                continue
            }

            let red = Int(data[offset]) >> 3
            let green = Int(data[offset + 1]) >> 3
            let blue = Int(data[offset + 2]) >> 3
            counts[(red << 10) | (green << 5) | blue, default: 0] += 1
        }
    }

    guard let key = counts.max(by: { $0.value < $1.value })?.key else {
        return (38, 148, 242)
    }

    let red = UInt8((((key >> 10) & 31) * 255) / 31)
    let green = UInt8((((key >> 5) & 31) * 255) / 31)
    let blue = UInt8(((key & 31) * 255) / 31)
    return (red, green, blue)
}

let background = dominantOpaqueColor(in: normalized, data: bitmapData)
let bytesPerRow = normalized.bytesPerRow
for y in 0..<sourceHeight {
    for x in 0..<sourceWidth {
        let offset = y * bytesPerRow + x * 4
        let red = Int(bitmapData[offset])
        let green = Int(bitmapData[offset + 1])
        let blue = Int(bitmapData[offset + 2])
        let redDelta = red - Int(background.0)
        let greenDelta = green - Int(background.1)
        let blueDelta = blue - Int(background.2)
        let isBackgroundColor = redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta < 3_600
        // The source is a finished rounded icon. Keep only the tower artwork and
        // let macOS/actool provide the final icon enclosure.
        let isArtworkArea =
            x > sourceWidth * 29 / 100 &&
            x < sourceWidth * 71 / 100 &&
            y > sourceHeight * 11 / 100 &&
            y < sourceHeight * 92 / 100

        if bitmapData[offset + 3] < 250 || isBackgroundColor || !isArtworkArea {
            bitmapData[offset] = background.0
            bitmapData[offset + 1] = background.1
            bitmapData[offset + 2] = background.2
        }
        bitmapData[offset + 3] = 255
    }
}

let baseImage = NSImage(size: NSSize(width: sourceWidth, height: sourceHeight))
baseImage.addRepresentation(normalized)

let slots = [
    Slot(pixels: 16, filename: "icon_16x16.png", size: "16x16", scale: "1x"),
    Slot(pixels: 32, filename: "icon_16x16@2x.png", size: "16x16", scale: "2x"),
    Slot(pixels: 32, filename: "icon_32x32.png", size: "32x32", scale: "1x"),
    Slot(pixels: 64, filename: "icon_32x32@2x.png", size: "32x32", scale: "2x"),
    Slot(pixels: 128, filename: "icon_128x128.png", size: "128x128", scale: "1x"),
    Slot(pixels: 256, filename: "icon_128x128@2x.png", size: "128x128", scale: "2x"),
    Slot(pixels: 256, filename: "icon_256x256.png", size: "256x256", scale: "1x"),
    Slot(pixels: 512, filename: "icon_256x256@2x.png", size: "256x256", scale: "2x"),
    Slot(pixels: 512, filename: "icon_512x512.png", size: "512x512", scale: "1x"),
    Slot(pixels: 1024, filename: "icon_512x512@2x.png", size: "512x512", scale: "2x"),
]

for slot in slots {
    let resized = makeBitmap(width: slot.pixels, height: slot.pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: resized) else {
        fputs("failed to create resized graphics context: \(slot.filename)\n", stderr)
        exit(1)
    }
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    baseImage.draw(
        in: NSRect(x: 0, y: 0, width: slot.pixels, height: slot.pixels),
        from: NSRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    let file = appIconSetDirectory.appendingPathComponent(slot.filename)
    guard let data = resized.representation(using: .png, properties: [:]) else {
        fputs("failed to encode png: \(slot.filename)\n", stderr)
        exit(1)
    }
    try data.write(to: file)
}

let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

let imageEntries = slots.map { slot in
    """
    {
      "filename" : "\(slot.filename)",
      "idiom" : "mac",
      "scale" : "\(slot.scale)",
      "size" : "\(slot.size)"
    }
    """
}.joined(separator: ",\n")

let appIconContents = """
{
  "images" : [
\(imageEntries)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

try catalogContents.write(
    to: catalogDirectory.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
try appIconContents.write(
    to: appIconSetDirectory.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
