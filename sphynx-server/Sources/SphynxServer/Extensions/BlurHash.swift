import Foundation

/// A pure-Swift [BlurHash](https://blurha.sh) encoder — turns a small RGB pixel
/// grid into the compact string the protocol's `Placeholder.blurHash` carries, so
/// a client can paint a blurred stand-in before the real image loads.
///
/// Self-contained (no platform image APIs), so it behaves identically on macOS and
/// the Linux deploy target and is unit-testable from synthetic pixels. Decoding the
/// source JPEG into pixels is the generator's job (`ImageBlurHashGenerator`); this
/// type only does the maths.
enum BlurHash {
    /// The BlurHash base-83 alphabet (order is significant).
    private static let alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    /// Encode a flat row-major RGB buffer (3 bytes per pixel) into a BlurHash.
    /// `componentsX`/`componentsY` (1...9) trade detail for length — 4×3 is the
    /// common default for posters. Returns nil on malformed input.
    static func encode(
        rgb: [UInt8], width: Int, height: Int, componentsX: Int = 4, componentsY: Int = 3
    ) -> String? {
        guard width > 0, height > 0, rgb.count == width * height * 3,
              (1...9).contains(componentsX), (1...9).contains(componentsY)
        else { return nil }

        // DCT-ish basis projection: factors[y * cx + x] holds one (r,g,b) coefficient
        // in linear light. factors[0] is the DC (average) term; the rest are AC.
        var factors: [(r: Double, g: Double, b: Double)] = []
        factors.reserveCapacity(componentsX * componentsY)
        for y in 0..<componentsY {
            for x in 0..<componentsX {
                let normalisation: Double = (x == 0 && y == 0) ? 1 : 2
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<height {
                    let basisY = cos(.pi * Double(y) * Double(j) / Double(height))
                    for i in 0..<width {
                        let basis = cos(.pi * Double(x) * Double(i) / Double(width)) * basisY
                        let p = (j * width + i) * 3
                        r += basis * sRGBToLinear(Int(rgb[p]))
                        g += basis * sRGBToLinear(Int(rgb[p + 1]))
                        b += basis * sRGBToLinear(Int(rgb[p + 2]))
                    }
                }
                let scale = normalisation / Double(width * height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        let dc = factors[0]
        let ac = factors.dropFirst()

        var hash = ""
        hash += encode83((componentsX - 1) + (componentsY - 1) * 9, length: 1)

        let maximumValue: Double
        if let actualMax = ac.map({ max(abs($0.r), abs($0.g), abs($0.b)) }).max(), !ac.isEmpty {
            let quantisedMax = max(0, min(82, Int(floor(actualMax * 166 - 0.5))))
            maximumValue = (Double(quantisedMax) + 1) / 166
            hash += encode83(quantisedMax, length: 1)
        } else {
            maximumValue = 1
            hash += encode83(0, length: 1)
        }

        hash += encode83(encodeDC(dc), length: 4)
        for component in ac {
            hash += encode83(encodeAC(component, maximumValue: maximumValue), length: 2)
        }
        return hash
    }

    // MARK: - Coefficient quantisation

    private static func encodeDC(_ c: (r: Double, g: Double, b: Double)) -> Int {
        (linearToSRGB(c.r) << 16) + (linearToSRGB(c.g) << 8) + linearToSRGB(c.b)
    }

    private static func encodeAC(_ c: (r: Double, g: Double, b: Double), maximumValue: Double) -> Int {
        func quant(_ value: Double) -> Int {
            max(0, min(18, Int(floor(signPow(value / maximumValue, 0.5) * 9 + 9.5))))
        }
        return quant(c.r) * 19 * 19 + quant(c.g) * 19 + quant(c.b)
    }

    // MARK: - Math helpers

    private static func signPow(_ value: Double, _ exp: Double) -> Double {
        copysign(pow(abs(value), exp), value)
    }

    private static func sRGBToLinear(_ value: Int) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Double) -> Int {
        let v = max(0, min(1, value))
        return v <= 0.0031308
            ? Int(v * 12.92 * 255 + 0.5)
            : Int((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for i in 1...length {
            let digit = (value / pow83(length - i)) % 83
            result.append(alphabet[digit])
        }
        return result
    }

    /// 83 raised to a small non-negative power (the only exponent base we need).
    private static func pow83(_ exponent: Int) -> Int {
        var result = 1
        for _ in 0..<exponent { result *= 83 }
        return result
    }
}
