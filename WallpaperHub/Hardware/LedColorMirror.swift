import Foundation
import AppKit
import CoreGraphics

/// Phase 8.3: 壁紙の最新フレームから領域別平均色を計算し、HW LED へ流す。
/// 描画パイプラインから定期的に CGImage が渡される想定で、ここでは「画像 → 色」の純粋関数群を主軸にする。
@MainActor
final class LedColorMirror: ObservableObject {

    /// 1 領域分の平均色 (0..255)
    struct LedColor: Equatable {
        var red: Int
        var green: Int
        var blue: Int
    }

    /// 横方向に何個の領域に分割するか (Razer の左/中央/右 → 3 が最小、最大 5)
    let regionCount: Int

    /// LED Boost 強度 (0..1)。彩度を最大 +20% (default 0.3 → 6%) ブーストする倍率の係数。
    @Published var boost: Double

    /// 最後に算出した色 (テスト/UI 監視用)
    @Published private(set) var lastColors: [LedColor] = []

    /// 連動先クライアント (省略可)
    weak var razer: RazerChromaClient?
    weak var corsair: CorsairCueClient?

    /// 30fps 更新の間隔 (秒)
    static let updateInterval: TimeInterval = 1.0 / 30.0

    init(regionCount: Int = 3, boost: Double = 0.3) {
        self.regionCount = max(3, min(5, regionCount))
        self.boost = boost
    }

    // MARK: - 純粋関数 API (テストから直接呼べる)

    /// CGImage を `regionCount` 個の縦長セグメントに分割し、
    /// 各領域の平均 RGB を計算して返す。
    /// 失敗 (画像読めない/サイズ 0 等) の場合は空配列を返す。
    nonisolated static func averageColors(in image: CGImage, regionCount: Int) -> [LedColor] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, regionCount > 0 else { return [] }

        // BGRA 8bit でビットマップを作って読む (sRGB)
        // Why: 安全な lifetime のため UnsafeMutableRawPointer.allocate を使い、
        //      CGContext から直接同じ buffer を読む。
        //      入力画像と同じ sRGB 空間にしておくことで gamma 変換による色漏れを避ける。
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let totalBytes = width * height * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: totalBytes, alignment: 4)
        defer { buffer.deallocate() }
        memset(buffer, 0, totalBytes)
        guard let ctx = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)

        var results: [LedColor] = []
        let segmentWidth = max(1, width / regionCount)

        for i in 0..<regionCount {
            let xStart = i * segmentWidth
            let xEnd = (i == regionCount - 1) ? width : (xStart + segmentWidth)
            var rSum: UInt64 = 0
            var gSum: UInt64 = 0
            var bSum: UInt64 = 0
            var count: UInt64 = 0

            // サンプル軽量化のため 4px 間隔でだけ拾う
            let step = max(1, (xEnd - xStart) / 32)
            let yStep = max(1, height / 32)

            var y = 0
            while y < height {
                var x = xStart
                while x < xEnd {
                    let offset = (y * bytesPerRow) + (x * 4)
                    rSum &+= UInt64(pixels[offset + 0])
                    gSum &+= UInt64(pixels[offset + 1])
                    bSum &+= UInt64(pixels[offset + 2])
                    count &+= 1
                    x += step
                }
                y += yStep
            }
            if count == 0 {
                results.append(LedColor(red: 0, green: 0, blue: 0))
            } else {
                results.append(LedColor(
                    red: Int(rSum / count),
                    green: Int(gSum / count),
                    blue: Int(bSum / count)
                ))
            }
        }
        return results
    }

    /// HSV 空間で彩度を boost 倍 (最大 +20%) 上げる純粋関数。
    /// boost は 0..1 にクランプされ、1.0 で +20% に到達する。
    nonisolated static func applyBoost(to color: LedColor, boost: Double) -> LedColor {
        let clampedBoost = max(0.0, min(1.0, boost))
        let multiplier = 1.0 + clampedBoost * 0.20
        let r = Double(color.red) / 255.0
        let g = Double(color.green) / 255.0
        let b = Double(color.blue) / 255.0
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let v = maxC
        let delta = maxC - minC
        let s = (maxC == 0) ? 0 : delta / maxC
        let h: Double
        if delta == 0 {
            h = 0
        } else if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = ((b - r) / delta) + 2
        } else {
            h = ((r - g) / delta) + 4
        }
        let boosted = min(1.0, s * multiplier)
        let (rr, gg, bb) = hsvToRgb(h: h, s: boosted, v: v)
        return LedColor(
            red: Int((rr * 255).rounded()),
            green: Int((gg * 255).rounded()),
            blue: Int((bb * 255).rounded())
        )
    }

    /// 簡易 HSV→RGB (h は 0..6 の hexant 座標)
    nonisolated private static func hsvToRgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h.rounded(.down)) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    // MARK: - 公開ヘルパー

    /// CGImage と現在の boost を使って領域別ブースト済み色を返し、`lastColors` に保存する
    @discardableResult
    func updateColors(from image: CGImage) -> [LedColor] {
        let raw = LedColorMirror.averageColors(in: image, regionCount: regionCount)
        let boosted = raw.map { LedColorMirror.applyBoost(to: $0, boost: boost) }
        self.lastColors = boosted
        return boosted
    }

    /// 算出済み色を Razer/Corsair に流す。中央 (index regionCount/2) を代表色として送る。
    func dispatchToHardware(_ colors: [LedColor]) async {
        guard !colors.isEmpty else { return }
        let center = colors[colors.count / 2]
        if let razer, razer.isConnected {
            let bgr = RazerChromaClient.bgrInt(red: center.red, green: center.green, blue: center.blue)
            await razer.sendKeyboardSolidColor(bgr: bgr)
        }
        if let corsair, corsair.isAvailable {
            corsair.sendSolidColor(red: center.red, green: center.green, blue: center.blue)
        }
    }
}
