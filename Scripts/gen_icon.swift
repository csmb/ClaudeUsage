#!/usr/bin/swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = "/tmp/ClaudeUsageIcons"

try! FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

func drawIcon(size: Int) -> Data? {
    let s = CGFloat(size)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = gc

    let ctx = gc.cgContext
    ctx.clear(CGRect(origin: .zero, size: CGSize(width: s, height: s)))
    let cs = CGColorSpaceCreateDeviceRGB()

    // --- Background: rounded rect with gradient #0F1117 (bottom) → #1A1F2E (top) ---
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth:  s * 0.2246,
        cornerHeight: s * 0.2246,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgColors = [
        CGColor(colorSpace: cs, components: [0.0588, 0.0667, 0.0902, 1.0])!,  // #0F1117
        CGColor(colorSpace: cs, components: [0.1020, 0.1216, 0.1804, 1.0])!,  // #1A1F2E
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGradient,
        start: CGPoint(x: s * 0.5, y: 0),
        end:   CGPoint(x: s * 0.5, y: s),
        options: [])
    ctx.restoreGState()

    // --- Bars ---
    let barWidth    = s * 0.22
    let barGap      = s * 0.20
    let maxBarH     = s * 0.52
    let minBarH     = s * 0.04
    let baseY       = s * 0.18
    let barRadius   = barWidth * 0.4
    let startX      = (s - (2 * barWidth + barGap)) / 2

    // (x-offset, height-fraction, R, G, B)
    let bars: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (startX,                    0.65, 0.133, 0.773, 0.369),  // green #22C55E
        (startX + barWidth + barGap, 0.40, 0.984, 0.749, 0.141), // yellow #FBBF24
    ]

    for (bx, frac, r, g, b) in bars {
        let barH = max(minBarH, frac * maxBarH)

        // Track (full-height ghost bar)
        let trackPath = CGPath(roundedRect: CGRect(x: bx, y: baseY, width: barWidth, height: maxBarH),
                               cornerWidth: barRadius, cornerHeight: barRadius, transform: nil)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.08])!)
        ctx.addPath(trackPath)
        ctx.fillPath()

        // Bar fill with subtle gradient (85% opacity at base → 100% at top)
        let barPath = CGPath(roundedRect: CGRect(x: bx, y: baseY, width: barWidth, height: barH),
                             cornerWidth: barRadius, cornerHeight: barRadius, transform: nil)
        ctx.saveGState()
        ctx.addPath(barPath)
        ctx.clip()
        let barColors = [
            CGColor(colorSpace: cs, components: [r, g, b, 0.85])!,
            CGColor(colorSpace: cs, components: [r, g, b, 1.00])!,
        ] as CFArray
        let barGradient = CGGradient(colorsSpace: cs, colors: barColors, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(barGradient,
            start: CGPoint(x: bx, y: baseY),
            end:   CGPoint(x: bx, y: baseY + barH),
            options: [])
        ctx.restoreGState()
    }

    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    if let data = drawIcon(size: size) {
        let path = "\(outputDir)/icon_\(size).png"
        try! data.write(to: URL(fileURLWithPath: path))
        print("✓ \(size)px")
    } else {
        print("✗ \(size)px — failed")
    }
}

print("Done → \(outputDir)")
