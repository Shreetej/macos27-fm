import Foundation
import CoreImage
let img = CIImage(contentsOf: URL(fileURLWithPath: "assets/qr.png"))!
let d = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
for f in d.features(in: img) {
    if let q = f as? CIQRCodeFeature { print("  Vision/CoreImage decoded: \(q.messageString ?? "nil")") }
}
