import Foundation

#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#else
import JPEG
#endif

/// Produces a BlurHash for any image (poster, backdrop, still, logo, banner, cast
/// face), for the **low-res-images** extension's `blurhash` mode. Abstracted so the
/// backfill can be unit-tested with a stub that returns a fixed hash instead of
/// hitting the network.
protocol BlurHashGenerating: Sendable {
    /// Fetch the image at `url`, decode it, and return a BlurHash. Best-effort:
    /// returns nil on any failure (bad URL, fetch error, undecodable image) so a
    /// missing hash never breaks anything — serving just falls back to the URL.
    func blurHash(forImageAt url: String) async -> String?
}

/// The production generator: fetches a (small, pre-sized) image with the shared
/// http(s)-only fetcher, decodes it into pixels, and BlurHash-encodes them. Role-
/// agnostic — the caller passes whichever tiny image URL it wants hashed.
///
/// Decoding is platform-split so we don't pay for a pure-Swift image decoder where
/// the OS already ships one: **ImageIO/CoreGraphics on Apple platforms** (and it
/// handles any format ImageIO knows), **swift-jpeg on Linux** (TMDB serves JPEG, so
/// JPEG-only there is fine). Either way an undecodable image yields nil.
struct ImageBlurHashGenerator: BlurHashGenerating {
    let fetcher: any HTTPFetching
    var componentsX = 4
    var componentsY = 3

    func blurHash(forImageAt url: String) async -> String? {
        guard let data = try? await fetcher.getData(url: url, headers: [:]),
              let decoded = Self.decodeRGB(data)
        else { return nil }
        return BlurHash.encode(rgb: decoded.rgb, width: decoded.width, height: decoded.height,
                               componentsX: componentsX, componentsY: componentsY)
    }

    /// Decode image bytes into a flat row-major RGB buffer (3 bytes/pixel).
    static func decodeRGB(_ data: Data) -> (rgb: [UInt8], width: Int, height: Int)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        // Render into a known RGBX byte layout (posters are opaque, so we skip the
        // alpha channel rather than premultiply), then drop the X byte per pixel.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        var i = 0
        while i < rgba.count {
            rgb.append(rgba[i]); rgb.append(rgba[i + 1]); rgb.append(rgba[i + 2])
            i += 4
        }
        return (rgb, width, height)
        #else
        var source = ByteSource(bytes: [UInt8](data))
        guard let image = try? JPEG.Data.Rectangular<JPEG.Common>.decompress(stream: &source)
        else { return nil }
        let (width, height) = image.size
        let pixels = image.unpack(as: JPEG.RGB.self)
        var rgb = [UInt8]()
        rgb.reserveCapacity(pixels.count * 3)
        for pixel in pixels {
            rgb.append(pixel.r); rgb.append(pixel.g); rgb.append(pixel.b)
        }
        return (rgb, width, height)
        #endif
    }
}

#if !canImport(ImageIO)
/// An in-memory `JPEG.Bytestream.Source` over a byte buffer, so we can decode the
/// fetched poster without touching the filesystem. (Linux path only — Apple uses
/// ImageIO.)
private struct ByteSource: JPEG.Bytestream.Source {
    let bytes: [UInt8]
    var position = 0

    mutating func read(count: Int) -> [UInt8]? {
        guard position + count <= bytes.count else { return nil }
        defer { position += count }
        return Array(bytes[position ..< position + count])
    }
}
#endif
