import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: create-icon.swift <output.icns>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

// ICNS chunk identifiers map to their physical PNG dimensions. Packaging the
// PNG chunks directly avoids depending on iconutil, which is not always paired
// correctly with the Command Line Tools installed on a newer macOS release.
let variants: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

func renderIcon(pixelSize: Int) throws -> Data {
    let size = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high
    let outerInset = size * 0.055
    let outerRect = NSRect(x: outerInset, y: outerInset, width: size - outerInset * 2, height: size - outerInset * 2)
    let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: size * 0.225, yRadius: size * 0.225)

    let gradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.42, alpha: 1), 0),
        (NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.76, alpha: 1), 0.52),
        (NSColor(calibratedRed: 0.08, green: 0.68, blue: 0.88, alpha: 1), 1)
    )!
    gradient.draw(in: outerPath, angle: -48)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    outerPath.lineWidth = max(1, size * 0.012)
    outerPath.stroke()

    let gridWidth = size * 0.59
    let tileGap = size * 0.055
    let tileSize = (gridWidth - tileGap * 2) / 3
    let gridOrigin = CGPoint(x: (size - gridWidth) / 2, y: (size - gridWidth) / 2)

    for row in 0..<3 {
        for column in 0..<3 {
            let x = gridOrigin.x + CGFloat(column) * (tileSize + tileGap)
            let y = gridOrigin.y + CGFloat(2 - row) * (tileSize + tileGap)
            let tileRect = NSRect(x: x, y: y, width: tileSize, height: tileSize)
            let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileSize * 0.28, yRadius: tileSize * 0.28)
            let alpha: CGFloat = (row == 1 && column == 1) ? 1 : 0.88
            NSColor.white.withAlphaComponent(alpha).setFill()
            tilePath.fill()
        }
    }

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LaunchIcon", code: 1)
    }
    return png
}

extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

var chunks = Data()
for (identifier, pixelSize) in variants {
    let png = try renderIcon(pixelSize: pixelSize)
    chunks.appendASCII(identifier)
    chunks.appendBigEndian(UInt32(png.count + 8))
    chunks.append(png)
}

var icon = Data()
icon.appendASCII("icns")
icon.appendBigEndian(UInt32(chunks.count + 8))
icon.append(chunks)
try icon.write(to: outputURL, options: .atomic)
