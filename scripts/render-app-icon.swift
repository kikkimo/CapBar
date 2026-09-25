import AppKit
import CoreGraphics
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "design/assets/capbar-app-icon.png"
let size = 1024
guard let bitmap = NSBitmapImageRep(
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
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon bitmap")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, alpha])!
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.setShouldAntialias(true)
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

let tile = CGPath(roundedRect: CGRect(x: 71, y: 78, width: 882, height: 882), cornerWidth: 214, cornerHeight: 214, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -20), blur: 36, color: color(0.10, 0.16, 0.25, 0.25))
context.addPath(tile)
context.setFillColor(color(0.96, 0.98, 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tile)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(1, 1, 1), color(0.92, 0.95, 0.99)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: 290, y: 930), end: CGPoint(x: 850, y: 90), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
context.restoreGState()
context.addPath(tile)
context.setStrokeColor(color(0.75, 0.79, 0.85, 0.65))
context.setLineWidth(3)
context.strokePath()

let center = CGPoint(x: 478, y: 515)
let radius: CGFloat = 240
context.addArc(center: center, radius: radius, startAngle: .pi / 4, endAngle: 7 * .pi / 4, clockwise: false)
context.setStrokeColor(color(0.18, 0.20, 0.24))
context.setLineWidth(106)
context.setLineCap(.round)
context.strokePath()

let dot = CGRect(x: 725, y: 464, width: 102, height: 102)
context.addEllipse(in: dot)
context.setFillColor(color(0.13, 0.45, 0.94))
context.fillPath()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try data.write(to: URL(fileURLWithPath: output))
print(output)
