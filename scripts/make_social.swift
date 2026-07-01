import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

let W = 1280, H = 640
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "social.png")

func c(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func rr(_ ctx: CGContext,_ rect: CGRect,_ rad: CGFloat,_ fill: CGColor) { ctx.setFillColor(fill); ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.fillPath() }

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true); ctx.setAllowsAntialiasing(true)

// background gradient (dark teal, matches app icon)
let bg = CGGradient(colorsSpace: cs, colors: [c(0.035,0.055,0.070), c(0.055,0.100,0.125), c(0.010,0.025,0.035)] as CFArray, locations: [0,0.55,1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: CGFloat(W), y: 0), options: [])

// ---- app-icon mark, drawn into a square badge on the left ----
func drawMark(_ ctx: CGContext, ox: CGFloat, oy: CGFloat, side: CGFloat) {
    ctx.saveGState(); ctx.translateBy(x: ox, y: oy)
    let size = side
    let inset = size*0.035
    let bgRect = CGRect(x: inset, y: inset, width: size-inset*2, height: size-inset*2)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: size*0.22, cornerHeight: size*0.22, transform: nil)); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [c(0.05,0.08,0.10), c(0.07,0.13,0.16), c(0.02,0.04,0.05)] as CFArray, locations: [0,0.55,1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: size*0.14, y: size*0.86), end: CGPoint(x: size*0.90, y: size*0.08), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(c(0.25,0.92,0.86,0.32)); ctx.setLineWidth(max(2,size*0.012))
    ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: size*0.22, cornerHeight: size*0.22, transform: nil)); ctx.strokePath()
    let centerY = size*0.55, barW = max(3,size*0.026), sp = size*0.055
    let hs: [CGFloat] = [0.16,0.26,0.38,0.30,0.20]
    for (i,ratio) in hs.enumerated() {
        let lx = size*0.19 + CGFloat(i)*sp, rx = size*0.81 - CGFloat(i+1)*sp
        let h = size*ratio, y = centerY - h/2
        let f = i==2 ? c(0.18,0.95,0.88,0.92) : c(0.60,1.00,0.96,0.35)
        rr(ctx, CGRect(x: lx, y: y, width: barW, height: h), barW/2, f)
        rr(ctx, CGRect(x: rx, y: y, width: barW, height: h), barW/2, f)
    }
    let mw = size*0.19, mh = size*0.38
    let mRect = CGRect(x: (size-mw)/2, y: size*0.39, width: mw, height: mh)
    rr(ctx, mRect, mw/2, c(0.91,1.00,0.98,0.95))
    rr(ctx, mRect.insetBy(dx: mw*0.28, dy: mw*0.18), mw*0.18, c(0.10,0.42,0.42,0.22))
    ctx.setStrokeColor(c(0.91,1.00,0.98,0.90)); ctx.setLineWidth(max(4,size*0.028)); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: size*0.50, y: size*0.35)); ctx.addLine(to: CGPoint(x: size*0.50, y: size*0.25))
    ctx.move(to: CGPoint(x: size*0.42, y: size*0.25)); ctx.addLine(to: CGPoint(x: size*0.58, y: size*0.25)); ctx.strokePath()
    ctx.setStrokeColor(c(0.18,0.95,0.88,0.82)); ctx.setLineWidth(max(4,size*0.024)); ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: size*0.50, y: size*0.48), radius: size*0.19, startAngle: 205 * .pi/180, endAngle: 335 * .pi/180, clockwise: false); ctx.strokePath()
    ctx.restoreGState()
}
let markSide: CGFloat = 340
drawMark(ctx, ox: 96, oy: CGFloat(H)/2 - markSide/2, side: markSide)

// ---- text ----
func text(_ s: String, font: String, size: CGFloat, color: CGColor, x: CGFloat, baseline: CGFloat, tracking: CGFloat = 0) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    var attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): color]
    if tracking != 0 { attrs[.init(kCTKernAttributeName as String)] = tracking }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.saveGState(); ctx.textMatrix = .identity; ctx.translateBy(x: x, y: baseline); CTLineDraw(line, ctx); ctx.restoreGState()
}

let tx: CGFloat = 500
text("SayKey", font: "HelveticaNeue-Bold", size: 150, color: c(0.94,1.00,0.99), x: tx, baseline: 372, tracking: 1)
text("按鍵說話，文字就落在游標處", font: "PingFangTC-Semibold", size: 46, color: c(0.22,0.95,0.88), x: tx+4, baseline: 300)
text("為中英混講而生 · 一律繁體中文 · 100% 本機離線", font: "PingFangTC-Medium", size: 33, color: c(0.80,0.88,0.90,0.92), x: tx+4, baseline: 236)
text("local whisper.cpp · no cloud · your voice never leaves the Mac", font: "HelveticaNeue-Medium", size: 24, color: c(0.55,0.70,0.72,0.85), x: tx+4, baseline: 190)

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
