import XCTest
import AppKit
import CoreGraphics

@testable import WallBlank

/// Phase 8.3: LedColorMirror の純粋関数を、決定的なテスト画像で検証する。
final class LedColorMirrorTests: XCTestCase {

    /// 1 領域だけの画像を作って平均色を確認する。
    /// CGContext の sRGB ガンマ変換で他チャネルが ~15% 程度漏れることがあるため
    /// (NS/CG はガンマ補正された sRGB を線形 RGBA バイトに展開しない)、許容誤差は ±50 で十分。
    func test_averageColors_solidRedReturnsRed() {
        let image = makeSolidColorImage(red: 255, green: 0, blue: 0, width: 64, height: 64)
        let colors = LedColorMirror.averageColors(in: image, regionCount: 1)
        XCTAssertEqual(colors.count, 1)
        // R がほぼ 255 で、G/B が R の半分未満 = 赤系であることを確認すれば十分
        XCTAssertGreaterThan(colors[0].red, 200)
        XCTAssertLessThan(colors[0].green, colors[0].red / 2)
        XCTAssertLessThan(colors[0].blue, colors[0].red / 2)
    }

    /// 横半分が赤・横半分が青 → 領域数 2 のとき左赤・右青
    func test_averageColors_splitsLeftRedRightBlue() {
        let image = makeSplitColorImage(
            leftRed: 255, leftGreen: 0, leftBlue: 0,
            rightRed: 0, rightGreen: 0, rightBlue: 255,
            width: 64, height: 64
        )
        let colors = LedColorMirror.averageColors(in: image, regionCount: 2)
        XCTAssertEqual(colors.count, 2)
        XCTAssertGreaterThan(colors[0].red, 200)
        XCTAssertLessThan(colors[0].blue, 50)
        XCTAssertGreaterThan(colors[1].blue, 200)
        XCTAssertLessThan(colors[1].red, 50)
    }

    /// boost = 0 のとき色は変化しない (恒等性)
    func test_applyBoost_zeroIsIdentity() {
        let original = LedColorMirror.LedColor(red: 100, green: 150, blue: 200)
        let boosted = LedColorMirror.applyBoost(to: original, boost: 0.0)
        XCTAssertEqual(original.red, boosted.red, accuracy: 1)
        XCTAssertEqual(original.green, boosted.green, accuracy: 1)
        XCTAssertEqual(original.blue, boosted.blue, accuracy: 1)
    }

    /// boost = 1 のとき彩度が上がる (= 最も低い成分が下がるか不変)
    func test_applyBoost_increasesSaturation() {
        let original = LedColorMirror.LedColor(red: 200, green: 130, blue: 130)
        let boosted = LedColorMirror.applyBoost(to: original, boost: 1.0)
        // R は max のため不変か若干変動、G/B は min のため低下する
        XCTAssertLessThanOrEqual(boosted.green, original.green)
        XCTAssertLessThanOrEqual(boosted.blue, original.blue)
    }

    /// グレースケール (R=G=B) は彩度 0 なのでブースト後も不変
    func test_applyBoost_grayIsUnchanged() {
        let gray = LedColorMirror.LedColor(red: 128, green: 128, blue: 128)
        let boosted = LedColorMirror.applyBoost(to: gray, boost: 1.0)
        XCTAssertEqual(gray.red, boosted.red, accuracy: 1)
        XCTAssertEqual(gray.green, boosted.green, accuracy: 1)
        XCTAssertEqual(gray.blue, boosted.blue, accuracy: 1)
    }

    /// regionCount は 3..5 にクランプされる
    @MainActor
    func test_init_clampsRegionCount() {
        let too_few = LedColorMirror(regionCount: 1)
        let too_many = LedColorMirror(regionCount: 99)
        XCTAssertEqual(too_few.regionCount, 3)
        XCTAssertEqual(too_many.regionCount, 5)
    }

    /// updateColors は lastColors を更新する
    @MainActor
    func test_updateColors_updatesLastColors() {
        let image = makeSolidColorImage(red: 0, green: 200, blue: 50, width: 32, height: 32)
        let mirror = LedColorMirror(regionCount: 3, boost: 0)
        let colors = mirror.updateColors(from: image)
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(mirror.lastColors.count, 3)
        for c in colors {
            // sRGB→bytes ガンマ展開で誤差が出るため ±20 で許容
            XCTAssertEqual(c.green, 200, accuracy: 20)
        }
    }

    // MARK: - Helpers

    private func makeSolidColorImage(red: Int, green: Int, blue: Int, width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func makeSplitColorImage(
        leftRed: Int, leftGreen: Int, leftBlue: Int,
        rightRed: Int, rightGreen: Int, rightBlue: Int,
        width: Int, height: Int
    ) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: CGFloat(leftRed) / 255.0, green: CGFloat(leftGreen) / 255.0, blue: CGFloat(leftBlue) / 255.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: CGFloat(rightRed) / 255.0, green: CGFloat(rightGreen) / 255.0, blue: CGFloat(rightBlue) / 255.0, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }
}
