// Renders the QChat app icon from the Android vector drawables
// (QChat/app/src/main/res/drawable/ic_launcher_{background,foreground}.xml) into the 1024 px PNG
// Xcode needs. Run:  swift tools/render-icon.swift QChat/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// Android draws on a 108 dp canvas and launchers show the inner ~72 dp; iOS applies its own
// rounded-square mask, so we crop the central 78 dp (a touch more breathing room) to fill 1024 px.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024
let visible: CGFloat = 78
let scale = CGFloat(size) / visible
let inset = (108 - visible) / 2

let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip to Android's top-left origin, then map dp → px.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: scale, y: -scale)
ctx.translateBy(x: -inset, y: -inset)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// ic_launcher_background: linear gradient #2B2F6B (0,0) → #10122A (108,108).
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x2B2F6B), rgb(0x10122A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 108, y: 108), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ic_launcher_foreground: speech bubble.
let bubble = CGMutablePath()
bubble.move(to: CGPoint(x: 34, y: 26))
bubble.addLine(to: CGPoint(x: 74, y: 26))
bubble.addArc(tangent1End: CGPoint(x: 86, y: 26), tangent2End: CGPoint(x: 86, y: 38), radius: 12)
bubble.addLine(to: CGPoint(x: 86, y: 62))
bubble.addArc(tangent1End: CGPoint(x: 86, y: 74), tangent2End: CGPoint(x: 74, y: 74), radius: 12)
bubble.addLine(to: CGPoint(x: 50, y: 74))
bubble.addLine(to: CGPoint(x: 38, y: 84))
bubble.addLine(to: CGPoint(x: 38, y: 74))
bubble.addLine(to: CGPoint(x: 34, y: 74))
bubble.addArc(tangent1End: CGPoint(x: 22, y: 74), tangent2End: CGPoint(x: 22, y: 62), radius: 12)
bubble.addLine(to: CGPoint(x: 22, y: 38))
bubble.addArc(tangent1End: CGPoint(x: 22, y: 26), tangent2End: CGPoint(x: 34, y: 26), radius: 12)
bubble.closeSubpath()
ctx.setFillColor(rgb(0xFFFFFF))
ctx.addPath(bubble)
ctx.fillPath()

// Q ring (centre 54,50 r 14) and tail, 6 dp strokes.
ctx.setStrokeColor(rgb(0x2B2F6B))
ctx.setLineWidth(6)
ctx.addEllipse(in: CGRect(x: 40, y: 36, width: 28, height: 28))
ctx.strokePath()
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 60, y: 56))
ctx.addLine(to: CGPoint(x: 69, y: 65))
ctx.strokePath()

// Accent spark.
let spark: [CGPoint] = [(80, 20), (82.5, 26), (88.5, 28.5), (82.5, 31), (80, 37), (77.5, 31), (71.5, 28.5), (77.5, 26)].map { CGPoint(x: $0.0, y: $0.1) }
ctx.setFillColor(rgb(0x7CE0FF))
ctx.addLines(between: spark)
ctx.closePath()
ctx.fillPath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("wrote \(out)")
