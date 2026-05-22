import Foundation
import AppKit
import Compression
import ImageIO

// MARK: - DDS Format Support

/// DDSピクセルフォーマット
struct DDSPixelFormat {
    let size: UInt32
    let flags: UInt32
    let fourCC: UInt32
    let rgbBitCount: UInt32
    let rBitMask: UInt32
    let gBitMask: UInt32
    let bBitMask: UInt32
    let aBitMask: UInt32
}

/// DDSヘッダー
struct DDSHeader {
    let magic: UInt32
    let size: UInt32
    let flags: UInt32
    let height: UInt32
    let width: UInt32
    let pitchOrLinearSize: UInt32
    let depth: UInt32
    let mipMapCount: UInt32
    let pixelFormat: DDSPixelFormat
    let caps: UInt32
    let caps2: UInt32
}

/// DDSデコーダー
class DDSDecoder {
    // FourCC constants
    static let DXT1: UInt32 = 0x31545844 // "DXT1"
    static let DXT3: UInt32 = 0x33545844 // "DXT3"
    static let DXT5: UInt32 = 0x35545844 // "DXT5"
    static let DX10: UInt32 = 0x30315844 // "DX10"

    static func decode(_ data: Data) throws -> NSImage {
        guard data.count >= 128 else {
            throw NSError(domain: "DDSDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "DDS data too small"])
        }

        // Parse header
        let header = try parseHeader(data)
        let width = Int(header.width)
        let height = Int(header.height)

        guard width > 0 && height > 0 && width <= 16384 && height <= 16384 else {
            throw NSError(domain: "DDSDecoder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid DDS dimensions: \(width)x\(height)"])
        }

        let pixelData: [UInt8]
        let headerSize = 128
        let textureData = Data(data[headerSize...])

        let fourCC = header.pixelFormat.fourCC

        if fourCC == DXT1 {
            pixelData = try decodeDXT1(textureData, width: width, height: height)
        } else if fourCC == DXT3 {
            pixelData = try decodeDXT3(textureData, width: width, height: height)
        } else if fourCC == DXT5 {
            pixelData = try decodeDXT5(textureData, width: width, height: height)
        } else if header.pixelFormat.flags & 0x40 != 0 { // DDPF_RGB
            pixelData = try decodeUncompressed(textureData, width: width, height: height, header: header)
        } else {
            throw NSError(domain: "DDSDecoder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported DDS format (FourCC: \(fourCCToString(fourCC)))"])
        }

        return try createImage(from: pixelData, width: width, height: height)
    }

    private static func fourCCToString(_ fourCC: UInt32) -> String {
        var chars = [Character]()
        for i in 0..<4 {
            let byte = UInt8((fourCC >> (i * 8)) & 0xFF)
            if byte >= 32 && byte < 127 {
                chars.append(Character(UnicodeScalar(byte)))
            } else {
                chars.append("?")
            }
        }
        return String(chars)
    }

    private static func parseHeader(_ data: Data) throws -> DDSHeader {
        return data.withUnsafeBytes { ptr in
            let magic = ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let size = ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let flags = ptr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let height = ptr.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let width = ptr.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            let pitchOrLinearSize = ptr.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            let depth = ptr.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
            let mipMapCount = ptr.loadUnaligned(fromByteOffset: 28, as: UInt32.self)

            // Pixel format at offset 76
            let pfSize = ptr.loadUnaligned(fromByteOffset: 76, as: UInt32.self)
            let pfFlags = ptr.loadUnaligned(fromByteOffset: 80, as: UInt32.self)
            let pfFourCC = ptr.loadUnaligned(fromByteOffset: 84, as: UInt32.self)
            let pfRGBBitCount = ptr.loadUnaligned(fromByteOffset: 88, as: UInt32.self)
            let pfRBitMask = ptr.loadUnaligned(fromByteOffset: 92, as: UInt32.self)
            let pfGBitMask = ptr.loadUnaligned(fromByteOffset: 96, as: UInt32.self)
            let pfBBitMask = ptr.loadUnaligned(fromByteOffset: 100, as: UInt32.self)
            let pfABitMask = ptr.loadUnaligned(fromByteOffset: 104, as: UInt32.self)

            let caps = ptr.loadUnaligned(fromByteOffset: 108, as: UInt32.self)
            let caps2 = ptr.loadUnaligned(fromByteOffset: 112, as: UInt32.self)

            let pixelFormat = DDSPixelFormat(
                size: pfSize, flags: pfFlags, fourCC: pfFourCC,
                rgbBitCount: pfRGBBitCount, rBitMask: pfRBitMask,
                gBitMask: pfGBitMask, bBitMask: pfBBitMask, aBitMask: pfABitMask
            )

            return DDSHeader(
                magic: magic, size: size, flags: flags,
                height: height, width: width, pitchOrLinearSize: pitchOrLinearSize,
                depth: depth, mipMapCount: mipMapCount, pixelFormat: pixelFormat,
                caps: caps, caps2: caps2
            )
        }
    }

    // MARK: - DXT1 Decoding
    private static func decodeDXT1(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let blocksX = (width + 3) / 4
        let blocksY = (height + 3) / 4

        data.withUnsafeBytes { ptr in
            var offset = 0
            for by in 0..<blocksY {
                for bx in 0..<blocksX {
                    guard offset + 8 <= data.count else { return }

                    let c0 = ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    let c1 = ptr.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
                    let indices = ptr.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                    offset += 8

                    let colors = decodeColorBlock(c0: c0, c1: c1, isDXT1: true)

                    for py in 0..<4 {
                        for px in 0..<4 {
                            let x = bx * 4 + px
                            let y = by * 4 + py
                            if x < width && y < height {
                                let idx = Int((indices >> ((py * 4 + px) * 2)) & 0x3)
                                let pixelIdx = (y * width + x) * 4
                                pixels[pixelIdx] = colors[idx].0     // R
                                pixels[pixelIdx + 1] = colors[idx].1 // G
                                pixels[pixelIdx + 2] = colors[idx].2 // B
                                pixels[pixelIdx + 3] = colors[idx].3 // A
                            }
                        }
                    }
                }
            }
        }
        return pixels
    }

    // MARK: - DXT3 Decoding
    private static func decodeDXT3(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let blocksX = (width + 3) / 4
        let blocksY = (height + 3) / 4

        data.withUnsafeBytes { ptr in
            var offset = 0
            for by in 0..<blocksY {
                for bx in 0..<blocksX {
                    guard offset + 16 <= data.count else { return }

                    // 8 bytes of alpha
                    var alphas = [UInt8](repeating: 255, count: 16)
                    for i in 0..<8 {
                        let byte = ptr.loadUnaligned(fromByteOffset: offset + i, as: UInt8.self)
                        alphas[i * 2] = (byte & 0x0F) * 17
                        alphas[i * 2 + 1] = (byte >> 4) * 17
                    }
                    offset += 8

                    let c0 = ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    let c1 = ptr.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
                    let indices = ptr.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                    offset += 8

                    let colors = decodeColorBlock(c0: c0, c1: c1, isDXT1: false)

                    for py in 0..<4 {
                        for px in 0..<4 {
                            let x = bx * 4 + px
                            let y = by * 4 + py
                            if x < width && y < height {
                                let idx = Int((indices >> ((py * 4 + px) * 2)) & 0x3)
                                let pixelIdx = (y * width + x) * 4
                                pixels[pixelIdx] = colors[idx].0
                                pixels[pixelIdx + 1] = colors[idx].1
                                pixels[pixelIdx + 2] = colors[idx].2
                                pixels[pixelIdx + 3] = alphas[py * 4 + px]
                            }
                        }
                    }
                }
            }
        }
        return pixels
    }

    // MARK: - DXT5 Decoding
    private static func decodeDXT5(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let blocksX = (width + 3) / 4
        let blocksY = (height + 3) / 4

        data.withUnsafeBytes { ptr in
            var offset = 0
            for by in 0..<blocksY {
                for bx in 0..<blocksX {
                    guard offset + 16 <= data.count else { return }

                    // Decode alpha block
                    let a0 = ptr.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
                    let a1 = ptr.loadUnaligned(fromByteOffset: offset + 1, as: UInt8.self)

                    var alphaIndices: UInt64 = 0
                    for i in 0..<6 {
                        let byte = UInt64(ptr.loadUnaligned(fromByteOffset: offset + 2 + i, as: UInt8.self))
                        alphaIndices |= byte << (i * 8)
                    }
                    offset += 8

                    let alphaTable = decodeAlphaTable(a0: a0, a1: a1)

                    let c0 = ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    let c1 = ptr.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
                    let indices = ptr.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                    offset += 8

                    let colors = decodeColorBlock(c0: c0, c1: c1, isDXT1: false)

                    for py in 0..<4 {
                        for px in 0..<4 {
                            let x = bx * 4 + px
                            let y = by * 4 + py
                            if x < width && y < height {
                                let colorIdx = Int((indices >> ((py * 4 + px) * 2)) & 0x3)
                                let alphaIdx = Int((alphaIndices >> ((py * 4 + px) * 3)) & 0x7)
                                let pixelIdx = (y * width + x) * 4
                                pixels[pixelIdx] = colors[colorIdx].0
                                pixels[pixelIdx + 1] = colors[colorIdx].1
                                pixels[pixelIdx + 2] = colors[colorIdx].2
                                pixels[pixelIdx + 3] = alphaTable[alphaIdx]
                            }
                        }
                    }
                }
            }
        }
        return pixels
    }

    // MARK: - Uncompressed Decoding
    private static func decodeUncompressed(_ data: Data, width: Int, height: Int, header: DDSHeader) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let bitCount = Int(header.pixelFormat.rgbBitCount)
        let bytesPerPixel = bitCount / 8

        let rMask = header.pixelFormat.rBitMask
        let gMask = header.pixelFormat.gBitMask
        let bMask = header.pixelFormat.bBitMask
        let aMask = header.pixelFormat.aBitMask

        let rShift = rMask == 0 ? 0 : UInt32(rMask.trailingZeroBitCount)
        let gShift = gMask == 0 ? 0 : UInt32(gMask.trailingZeroBitCount)
        let bShift = bMask == 0 ? 0 : UInt32(bMask.trailingZeroBitCount)
        let aShift = aMask == 0 ? 0 : UInt32(aMask.trailingZeroBitCount)

        let rMax = rMask == 0 ? 1 : Float(rMask >> rShift)
        let gMax = gMask == 0 ? 1 : Float(gMask >> gShift)
        let bMax = bMask == 0 ? 1 : Float(bMask >> bShift)
        let aMax = aMask == 0 ? 1 : Float(aMask >> aShift)

        data.withUnsafeBytes { ptr in
            for y in 0..<height {
                for x in 0..<width {
                    let srcIdx = (y * width + x) * bytesPerPixel
                    guard srcIdx + bytesPerPixel <= data.count else { continue }

                    var pixel: UInt32 = 0
                    for i in 0..<bytesPerPixel {
                        pixel |= UInt32(ptr.loadUnaligned(fromByteOffset: srcIdx + i, as: UInt8.self)) << (i * 8)
                    }

                    let dstIdx = (y * width + x) * 4
                    pixels[dstIdx] = UInt8(Float((pixel & rMask) >> rShift) / rMax * 255)
                    pixels[dstIdx + 1] = UInt8(Float((pixel & gMask) >> gShift) / gMax * 255)
                    pixels[dstIdx + 2] = UInt8(Float((pixel & bMask) >> bShift) / bMax * 255)
                    pixels[dstIdx + 3] = aMask == 0 ? 255 : UInt8(Float((pixel & aMask) >> aShift) / aMax * 255)
                }
            }
        }
        return pixels
    }

    // MARK: - Helper Functions
    private static func decodeColorBlock(c0: UInt16, c1: UInt16, isDXT1: Bool) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let r0 = UInt8(((c0 >> 11) & 0x1F) * 255 / 31)
        let g0 = UInt8(((c0 >> 5) & 0x3F) * 255 / 63)
        let b0 = UInt8((c0 & 0x1F) * 255 / 31)

        let r1 = UInt8(((c1 >> 11) & 0x1F) * 255 / 31)
        let g1 = UInt8(((c1 >> 5) & 0x3F) * 255 / 63)
        let b1 = UInt8((c1 & 0x1F) * 255 / 31)

        var colors: [(UInt8, UInt8, UInt8, UInt8)] = [
            (r0, g0, b0, 255),
            (r1, g1, b1, 255),
            (0, 0, 0, 255),
            (0, 0, 0, 255)
        ]

        if isDXT1 && c0 <= c1 {
            colors[2] = (UInt8((Int(r0) + Int(r1)) / 2), UInt8((Int(g0) + Int(g1)) / 2), UInt8((Int(b0) + Int(b1)) / 2), 255)
            colors[3] = (0, 0, 0, 0) // Transparent
        } else {
            colors[2] = (UInt8((Int(r0) * 2 + Int(r1)) / 3), UInt8((Int(g0) * 2 + Int(g1)) / 3), UInt8((Int(b0) * 2 + Int(b1)) / 3), 255)
            colors[3] = (UInt8((Int(r0) + Int(r1) * 2) / 3), UInt8((Int(g0) + Int(g1) * 2) / 3), UInt8((Int(b0) + Int(b1) * 2) / 3), 255)
        }

        return colors
    }

    private static func decodeAlphaTable(a0: UInt8, a1: UInt8) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 8)
        table[0] = a0
        table[1] = a1

        if a0 > a1 {
            table[2] = UInt8((6 * Int(a0) + 1 * Int(a1)) / 7)
            table[3] = UInt8((5 * Int(a0) + 2 * Int(a1)) / 7)
            table[4] = UInt8((4 * Int(a0) + 3 * Int(a1)) / 7)
            table[5] = UInt8((3 * Int(a0) + 4 * Int(a1)) / 7)
            table[6] = UInt8((2 * Int(a0) + 5 * Int(a1)) / 7)
            table[7] = UInt8((1 * Int(a0) + 6 * Int(a1)) / 7)
        } else {
            table[2] = UInt8((4 * Int(a0) + 1 * Int(a1)) / 5)
            table[3] = UInt8((3 * Int(a0) + 2 * Int(a1)) / 5)
            table[4] = UInt8((2 * Int(a0) + 3 * Int(a1)) / 5)
            table[5] = UInt8((1 * Int(a0) + 4 * Int(a1)) / 5)
            table[6] = 0
            table[7] = 255
        }
        return table
    }

    private static func createImage(from pixels: [UInt8], width: Int, height: Int) throws -> NSImage {
        let bitsPerComponent = 8
        let bitsPerPixel = 32
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: bitsPerComponent,
                  bitsPerPixel: bitsPerPixel,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw NSError(domain: "DDSDecoder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

// MARK: - Texture Format Detection

enum TextureFormat: String {
    case png = "PNG"
    case jpeg = "JPEG"
    case dds = "DDS"
    case webp = "WebP"
    case tga = "TGA"
    case bmp = "BMP"
    case gif = "GIF"
    case unknown = "Unknown"

    static func detect(from data: Data) -> TextureFormat {
        guard data.count >= 4 else { return .unknown }

        return data.withUnsafeBytes { ptr in
            let b0 = ptr.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let b1 = ptr.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
            let b2 = ptr.loadUnaligned(fromByteOffset: 2, as: UInt8.self)
            let b3 = ptr.loadUnaligned(fromByteOffset: 3, as: UInt8.self)

            // PNG: 89 50 4E 47
            if b0 == 0x89 && b1 == 0x50 && b2 == 0x4E && b3 == 0x47 {
                return .png
            }
            // JPEG: FF D8 FF
            if b0 == 0xFF && b1 == 0xD8 && b2 == 0xFF {
                return .jpeg
            }
            // DDS: "DDS " (44 44 53 20)
            if b0 == 0x44 && b1 == 0x44 && b2 == 0x53 && b3 == 0x20 {
                return .dds
            }
            // WebP: "RIFF" + "WEBP"
            if b0 == 0x52 && b1 == 0x49 && b2 == 0x46 && b3 == 0x46 {
                if data.count >= 12 {
                    let b8 = ptr.loadUnaligned(fromByteOffset: 8, as: UInt8.self)
                    let b9 = ptr.loadUnaligned(fromByteOffset: 9, as: UInt8.self)
                    let b10 = ptr.loadUnaligned(fromByteOffset: 10, as: UInt8.self)
                    let b11 = ptr.loadUnaligned(fromByteOffset: 11, as: UInt8.self)
                    if b8 == 0x57 && b9 == 0x45 && b10 == 0x42 && b11 == 0x50 {
                        return .webp
                    }
                }
            }
            // BMP: "BM"
            if b0 == 0x42 && b1 == 0x4D {
                return .bmp
            }
            // GIF: "GIF8"
            if b0 == 0x47 && b1 == 0x49 && b2 == 0x46 && b3 == 0x38 {
                return .gif
            }

            return .unknown
        }
    }
}

/// 簡易PKGリーダー（SwiftImageライブラリ不要版）
class PkgReader {
    static let MAGIC = Data("PKGV".utf8)

    let path: URL
    private var data: Data
    private var entries: [PkgEntry] = []
    private var dataStart: Int = 0

    init(path: String) throws {
        self.path = URL(fileURLWithPath: path)
        // ファイルサイズを事前チェックし、大きすぎる場合はエラーにする
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = fileAttributes[.size] as? UInt64 ?? 0
        let maxPkgSize: UInt64 = 512 * 1024 * 1024 // 512MB上限
        guard fileSize <= maxPkgSize else {
            throw NSError(domain: "PkgReader", code: 7, userInfo: [NSLocalizedDescriptionKey: "PKGファイルが大きすぎます（\(fileSize / 1024 / 1024)MB）。上限は\(maxPkgSize / 1024 / 1024)MBです"])
        }
        self.data = try Data(contentsOf: self.path)
        try parseToc()
    }

    private func parseToc() throws {
        guard data.count >= 16 else {
            throw NSError(domain: "PkgReader", code: 6, userInfo: [NSLocalizedDescriptionKey: "PKGファイルが小さすぎます"])
        }
        let magic = data[4..<8]
        guard magic == PkgReader.MAGIC else {
            throw NSError(domain: "PkgReader", code: 6, userInfo: [NSLocalizedDescriptionKey: "PKGファイルではありません"])
        }

        var pos = 16
        while pos + 4 <= data.count {
            var nameLen: UInt32 = 0
            data.withUnsafeBytes { ptr in
                nameLen = ptr.loadUnaligned(fromByteOffset: pos, as: UInt32.self)
            }
            if nameLen == 0 || nameLen > 4096 {
                break
            }
            pos += 4

            // 境界チェック: ファイル名 + offset(4) + size(4) が収まるか確認
            let requiredBytes = Int(nameLen) + 8
            guard pos + requiredBytes <= data.count else {
                debugLog("[PkgReader] TOC解析中に境界外アクセスを検出。解析を終了します")
                break
            }

            let name = String(data: data[pos..<(pos+Int(nameLen))], encoding: .utf8) ?? ""
            pos += Int(nameLen)

            var offset: UInt32 = 0
            var size: UInt32 = 0
            data.withUnsafeBytes { ptr in
                offset = ptr.loadUnaligned(fromByteOffset: pos, as: UInt32.self)
                size = ptr.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self)
            }
            pos += 8
            entries.append(PkgEntry(name: name, offset: Int(offset), size: Int(size)))
        }

        dataStart = pos
    }

    func listTextures() -> [[String: Any]] {
        var result = [[String: Any]]()
        for e in entries {
            if e.name.hasSuffix(".tex") {
                result.append([
                    "name": e.name,
                    "size": e.size,
                ])
            }
        }
        return result
    }

    func readFile(name: String) throws -> Data {
        let entry = try find(name: name)
        return try readRaw(entry: entry)
    }

    func readTextureAsImage(name: String) throws -> NSImage {
        let raw = try readFile(name: name)

        // まずデータ内でテクスチャフォーマットを検索
        // Wallpaper Engine .tex ファイルはヘッダー付きで画像データを含む

        // DDS形式を検索 (Wallpaper Engineで最も一般的)
        if let ddsRange = raw.range(of: Data([0x44, 0x44, 0x53, 0x20])) { // "DDS "
            let ddsData = Data(raw[ddsRange.lowerBound...])
            do {
                return try DDSDecoder.decode(ddsData)
            } catch {
                debugLog("[PkgReader] DDS decode failed: \(error.localizedDescription)")
            }
        }

        // PNG形式を検索
        if let pngRange = raw.range(of: Data([0x89, 0x50, 0x4E, 0x47])) {
            let imageData = Data(raw[pngRange.lowerBound...])
            if let image = NSImage(data: imageData) {
                return image
            }
        }

        // JPEG形式を検索
        if let jpegRange = raw.range(of: Data([0xFF, 0xD8, 0xFF])) {
            let imageData = Data(raw[jpegRange.lowerBound...])
            if let image = NSImage(data: imageData) {
                return image
            }
        }

        // WebP形式を検索 ("RIFF" + "WEBP")
        if let riffRange = raw.range(of: Data([0x52, 0x49, 0x46, 0x46])) {
            let offset = riffRange.lowerBound
            if offset + 12 <= raw.count {
                let webpSignature = raw[(offset + 8)..<(offset + 12)]
                if webpSignature == Data([0x57, 0x45, 0x42, 0x50]) { // "WEBP"
                    let webpData = Data(raw[offset...])
                    if let image = NSImage(data: webpData) {
                        return image
                    }
                }
            }
        }

        // BMP形式を検索
        if let bmpRange = raw.range(of: Data([0x42, 0x4D])) { // "BM"
            let bmpData = Data(raw[bmpRange.lowerBound...])
            if let image = NSImage(data: bmpData) {
                return image
            }
        }

        // GIF形式を検索
        if let gifRange = raw.range(of: Data([0x47, 0x49, 0x46, 0x38])) { // "GIF8"
            let gifData = Data(raw[gifRange.lowerBound...])
            if let image = NSImage(data: gifData) {
                return image
            }
        }

        // TGA形式（ヘッダーなしでマジックバイトがないため、最後の手段として試行）
        // TGAは先頭にIDフィールド長を持つ
        if raw.count > 18 {
            // TGAヘッダーを解析
            if let image = tryDecodeTGA(raw) {
                return image
            }
        }

        // 最後の手段：ImageIOで直接試行
        if let source = CGImageSourceCreateWithData(raw as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        // 検出されたフォーマットを特定してエラーメッセージに含める
        let detectedFormat = detectRawFormat(raw)
        throw NSError(domain: "PkgReader", code: 100, userInfo: [
            NSLocalizedDescriptionKey: "Unsupported texture format: \(detectedFormat). Supported formats: PNG, JPEG, DDS (DXT1/DXT3/DXT5), WebP, BMP, GIF, TGA."
        ])
    }

    /// TGAフォーマットのデコードを試行
    private func tryDecodeTGA(_ data: Data) -> NSImage? {
        guard data.count > 18 else { return nil }

        return data.withUnsafeBytes { ptr in
            let idLength = ptr.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let colorMapType = ptr.loadUnaligned(fromByteOffset: 1, as: UInt8.self)
            let imageType = ptr.loadUnaligned(fromByteOffset: 2, as: UInt8.self)

            // 有効なTGAイメージタイプをチェック (2=非圧縮RGB, 10=RLE RGB)
            guard (imageType == 2 || imageType == 10) && colorMapType <= 1 else {
                return nil
            }

            let width = Int(ptr.loadUnaligned(fromByteOffset: 12, as: UInt16.self))
            let height = Int(ptr.loadUnaligned(fromByteOffset: 14, as: UInt16.self))
            let bpp = ptr.loadUnaligned(fromByteOffset: 16, as: UInt8.self)

            guard width > 0 && height > 0 && width <= 16384 && height <= 16384 else {
                return nil
            }
            guard bpp == 24 || bpp == 32 else {
                return nil
            }

            let headerSize = 18 + Int(idLength)
            guard data.count > headerSize else { return nil }

            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let bytesPerPixel = Int(bpp) / 8
            var srcOffset = headerSize

            if imageType == 2 {
                // 非圧縮
                for y in 0..<height {
                    for x in 0..<width {
                        guard srcOffset + bytesPerPixel <= data.count else { return nil }
                        let dstY = height - 1 - y // TGAは下から上
                        let dstIdx = (dstY * width + x) * 4

                        let b = ptr.loadUnaligned(fromByteOffset: srcOffset, as: UInt8.self)
                        let g = ptr.loadUnaligned(fromByteOffset: srcOffset + 1, as: UInt8.self)
                        let r = ptr.loadUnaligned(fromByteOffset: srcOffset + 2, as: UInt8.self)
                        let a = bytesPerPixel == 4 ? ptr.loadUnaligned(fromByteOffset: srcOffset + 3, as: UInt8.self) : 255

                        pixels[dstIdx] = r
                        pixels[dstIdx + 1] = g
                        pixels[dstIdx + 2] = b
                        pixels[dstIdx + 3] = a

                        srcOffset += bytesPerPixel
                    }
                }
            } else {
                // RLE圧縮 (imageType == 10)
                var pixelIndex = 0
                let totalPixels = width * height

                while pixelIndex < totalPixels && srcOffset < data.count {
                    let packet = ptr.loadUnaligned(fromByteOffset: srcOffset, as: UInt8.self)
                    srcOffset += 1

                    let count = Int(packet & 0x7F) + 1

                    if packet & 0x80 != 0 {
                        // RLEパケット
                        guard srcOffset + bytesPerPixel <= data.count else { return nil }
                        let b = ptr.loadUnaligned(fromByteOffset: srcOffset, as: UInt8.self)
                        let g = ptr.loadUnaligned(fromByteOffset: srcOffset + 1, as: UInt8.self)
                        let r = ptr.loadUnaligned(fromByteOffset: srcOffset + 2, as: UInt8.self)
                        let a = bytesPerPixel == 4 ? ptr.loadUnaligned(fromByteOffset: srcOffset + 3, as: UInt8.self) : 255
                        srcOffset += bytesPerPixel

                        for _ in 0..<count {
                            if pixelIndex >= totalPixels { break }
                            let x = pixelIndex % width
                            let y = height - 1 - (pixelIndex / width)
                            let dstIdx = (y * width + x) * 4
                            pixels[dstIdx] = r
                            pixels[dstIdx + 1] = g
                            pixels[dstIdx + 2] = b
                            pixels[dstIdx + 3] = a
                            pixelIndex += 1
                        }
                    } else {
                        // Rawパケット
                        for _ in 0..<count {
                            if pixelIndex >= totalPixels { break }
                            guard srcOffset + bytesPerPixel <= data.count else { return nil }
                            let x = pixelIndex % width
                            let y = height - 1 - (pixelIndex / width)
                            let dstIdx = (y * width + x) * 4

                            let b = ptr.loadUnaligned(fromByteOffset: srcOffset, as: UInt8.self)
                            let g = ptr.loadUnaligned(fromByteOffset: srcOffset + 1, as: UInt8.self)
                            let r = ptr.loadUnaligned(fromByteOffset: srcOffset + 2, as: UInt8.self)
                            let a = bytesPerPixel == 4 ? ptr.loadUnaligned(fromByteOffset: srcOffset + 3, as: UInt8.self) : 255
                            srcOffset += bytesPerPixel

                            pixels[dstIdx] = r
                            pixels[dstIdx + 1] = g
                            pixels[dstIdx + 2] = b
                            pixels[dstIdx + 3] = a
                            pixelIndex += 1
                        }
                    }
                }
            }

            // CGImageを作成
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let cgImage = CGImage(
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo,
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  ) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
    }

    /// 生データのフォーマットを検出（エラーメッセージ用）
    private func detectRawFormat(_ data: Data) -> String {
        guard data.count >= 16 else { return "Unknown (data too small)" }

        // 既知のシグネチャを検索
        let signatures: [(Data, String)] = [
            (Data([0x44, 0x44, 0x53, 0x20]), "DDS"),
            (Data([0x89, 0x50, 0x4E, 0x47]), "PNG"),
            (Data([0xFF, 0xD8, 0xFF]), "JPEG"),
            (Data([0x52, 0x49, 0x46, 0x46]), "RIFF (possibly WebP)"),
            (Data([0x42, 0x4D]), "BMP"),
            (Data([0x47, 0x49, 0x46, 0x38]), "GIF"),
        ]

        for (signature, name) in signatures {
            if data.range(of: signature) != nil {
                return name
            }
        }

        // 最初の16バイトをヘックスで表示
        let header = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "Unknown (header: \(header))"
    }

    private func find(name: String) throws -> PkgEntry {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw NSError(domain: "PkgReader", code: 12, userInfo: [NSLocalizedDescriptionKey: "'\(name)' not found in PKG"])
        }
        return entry
    }

    private func readRaw(entry: PkgEntry) throws -> Data {
        let start = dataStart + entry.offset
        let end = start + entry.size
        guard start >= 0, end <= data.count, start <= end else {
            throw NSError(domain: "PkgReader", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Buffer boundary exceeded: offset=\(entry.offset), size=\(entry.size), dataSize=\(data.count)"
            ])
        }
        return data[start..<end]
    }
}

struct PkgEntry {
    let name: String
    let offset: Int
    let size: Int
}

/// NSImageを保存するヘルパー関数
func saveImage(_ image: NSImage, to url: URL, format: String) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData) else {
        throw NSError(domain: "PkgReader", code: 17, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap representation"])
    }

    let imageData: Data?
    if format == "jpeg" || format == "jpg" {
        imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    } else {
        imageData = bitmapRep.representation(using: .png, properties: [:])
    }

    guard let data = imageData else {
        throw NSError(domain: "PkgReader", code: 18, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
    }

    try data.write(to: url)
}
