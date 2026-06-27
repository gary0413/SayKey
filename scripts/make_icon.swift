#!/usr/bin/env swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first ?? "Resources/SayKey.icns"
let outputURL = URL(fileURLWithPath: outputPath)
let resourcesURL = outputURL.deletingLastPathComponent()
let iconsetURL = resourcesURL.appendingPathComponent("SayKey.iconset", isDirectory: true)

let fileManager = FileManager.default
try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconsetURL)
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

func fillRoundedRect(_ context: CGContext, _ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

func strokeRoundedRect(_ context: CGContext, _ rect: CGRect, _ radius: CGFloat, _ stroke: CGColor, lineWidth: CGFloat) {
    context.setStrokeColor(stroke)
    context.setLineWidth(lineWidth)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.strokePath()
}

func drawIcon(pixelSize: Int) throws -> CGImage {
    let size = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(
            domain: "SayKeyIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create CGContext"]
        )
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let inset = size * 0.035
    let backgroundRect = rect(inset, inset, size - inset * 2, size - inset * 2)
    let backgroundPath = CGPath(
        roundedRect: backgroundRect,
        cornerWidth: size * 0.22,
        cornerHeight: size * 0.22,
        transform: nil
    )

    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()
    let gradientColors = [
        color(0.035, 0.055, 0.070),
        color(0.055, 0.095, 0.120),
        color(0.010, 0.025, 0.035)
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 0.55, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: size * 0.14, y: size * 0.86),
        end: CGPoint(x: size * 0.90, y: size * 0.08),
        options: []
    )
    context.restoreGState()

    strokeRoundedRect(
        context,
        backgroundRect,
        size * 0.22,
        color(0.25, 0.92, 0.86, 0.32),
        lineWidth: max(2, size * 0.012)
    )

    let centerY = size * 0.55
    let barWidth = max(3, size * 0.026)
    let barSpacing = size * 0.055
    let barHeights: [CGFloat] = [0.16, 0.26, 0.38, 0.30, 0.20]
    for (index, ratio) in barHeights.enumerated() {
        let leftX = size * 0.19 + CGFloat(index) * barSpacing
        let rightX = size * 0.81 - CGFloat(index + 1) * barSpacing
        let height = size * ratio
        let y = centerY - height / 2
        let fill = index == 2
            ? color(0.18, 0.95, 0.88, 0.92)
            : color(0.60, 1.00, 0.96, 0.35)
        fillRoundedRect(context, rect(leftX, y, barWidth, height), barWidth / 2, fill)
        fillRoundedRect(context, rect(rightX, y, barWidth, height), barWidth / 2, fill)
    }

    let micWidth = size * 0.19
    let micHeight = size * 0.38
    let micRect = rect((size - micWidth) / 2, size * 0.39, micWidth, micHeight)
    fillRoundedRect(context, micRect, micWidth / 2, color(0.91, 1.00, 0.98, 0.95))

    let micInner = micRect.insetBy(dx: micWidth * 0.28, dy: micWidth * 0.18)
    fillRoundedRect(context, micInner, micInner.width / 2, color(0.10, 0.42, 0.42, 0.22))

    context.setStrokeColor(color(0.91, 1.00, 0.98, 0.90))
    context.setLineWidth(max(4, size * 0.028))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: size * 0.50, y: size * 0.35))
    context.addLine(to: CGPoint(x: size * 0.50, y: size * 0.25))
    context.move(to: CGPoint(x: size * 0.42, y: size * 0.25))
    context.addLine(to: CGPoint(x: size * 0.58, y: size * 0.25))
    context.strokePath()

    context.setStrokeColor(color(0.18, 0.95, 0.88, 0.82))
    context.setLineWidth(max(4, size * 0.024))
    context.setLineCap(.round)
    context.addArc(
        center: CGPoint(x: size * 0.50, y: size * 0.48),
        radius: size * 0.19,
        startAngle: 205 * .pi / 180,
        endAngle: 335 * .pi / 180,
        clockwise: false
    )
    context.strokePath()

    guard let image = context.makeImage() else {
        throw NSError(
            domain: "SayKeyIcon",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not make CGImage"]
        )
    }
    return image
}

func writePNG(pixelSize: Int, fileName: String) throws {
    let image = try drawIcon(pixelSize: pixelSize)
    let url = iconsetURL.appendingPathComponent(fileName)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(
            domain: "SayKeyIcon",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"]
        )
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(
            domain: "SayKeyIcon",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not write \(fileName)"]
        )
    }
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for variant in variants {
    try writePNG(pixelSize: variant.0, fileName: variant.1)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(
        domain: "SayKeyIcon",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
    )
}
