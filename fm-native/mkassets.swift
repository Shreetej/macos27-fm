// Generate deterministic test assets locally: no downloads, fully reproducible.
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func writePNG(_ cg: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("FAIL dest \(name)"); return
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

// ---- 1. QR code with a known payload -----------------------------------------
let payload = "INV-2026-00417|AMT=4820.50|CUR=INR"
let f = CIFilter(name: "CIQRCodeGenerator")!
f.setValue(payload.data(using: .utf8), forKey: "inputMessage")
f.setValue("H", forKey: "inputCorrectionLevel")
let scaled = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
let ctx = CIContext()
writePNG(ctx.createCGImage(scaled, from: scaled.extent)!, "qr.png")
print("qr payload: \(payload)")

// ---- 2. A receipt-like text image, for OCR -----------------------------------
let lines = [
    "ACME HARDWARE SUPPLY",
    "Invoice  INV-2026-00417",
    "Date     19 October 2026",
    "",
    "Hex bolts M8 x 40      120 pcs    1,440.00",
    "Washers  M8             300 pcs      390.00",
    "Thread lock 50ml          4 pcs      560.00",
    "",
    "Subtotal                           2,390.00",
    "GST 18%                              430.20",
    "TOTAL                              2,820.20",
]
let W = 900, H = 560
let cs = CGColorSpaceCreateDeviceRGB()
let bmp = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bmp.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
bmp.fill(CGRect(x: 0, y: 0, width: W, height: H))

let nsctx = NSGraphicsContext(cgContext: bmp, flipped: false)
NSGraphicsContext.current = nsctx
let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
for (i, line) in lines.enumerated() {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    NSAttributedString(string: line, attributes: attrs)
        .draw(at: NSPoint(x: 40, y: CGFloat(H - 60 - i * 42)))
}
NSGraphicsContext.current = nil
writePNG(bmp.makeImage()!, "receipt.png")

// ---- 3. A simple chart-like figure, for image description ---------------------
let W2 = 700, H2 = 420
let b2 = CGContext(data: nil, width: W2, height: H2, bitsPerComponent: 8, bytesPerRow: 0,
                   space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
b2.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
b2.fill(CGRect(x: 0, y: 0, width: W2, height: H2))
let bars: [(String, CGFloat)] = [("Mon", 60), ("Tue", 140), ("Wed", 95), ("Thu", 210), ("Fri", 170)]
b2.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1))
for (i, bar) in bars.enumerated() {
    b2.fill(CGRect(x: CGFloat(70 + i * 110), y: 70, width: 70, height: bar.1))
}
b2.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
b2.setLineWidth(2)
b2.move(to: CGPoint(x: 50, y: 70)); b2.addLine(to: CGPoint(x: 660, y: 70)); b2.strokePath()
let nsctx2 = NSGraphicsContext(cgContext: b2, flipped: false)
NSGraphicsContext.current = nsctx2
let f2 = NSFont.systemFont(ofSize: 20)
for (i, bar) in bars.enumerated() {
    NSAttributedString(string: bar.0, attributes: [.font: f2, .foregroundColor: NSColor.black])
        .draw(at: NSPoint(x: 85 + i * 110, y: 40))
}
NSAttributedString(string: "Units shipped per day",
                   attributes: [.font: NSFont.boldSystemFont(ofSize: 24),
                                .foregroundColor: NSColor.black])
    .draw(at: NSPoint(x: 60, y: 360))
NSGraphicsContext.current = nil
writePNG(b2.makeImage()!, "chart.png")
