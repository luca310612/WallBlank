import AppKit
import CoreGraphics
import CoreText
import Foundation

// Phase 4B: Text レイヤー — Core Text + CGContext でテキストを CGImage 化する。
// Why: 同梱フォントが無くてもシステムフォントへフォールバックするので、
//      ライセンス未確認のフォント同梱は見送り、Core Text 経由のレンダのみで完結させる。

/// テキスト整列 (Rust 側ではテキストレンダ非対応のため Swift 内のみ)。
enum TextLayerAlignment: String, Codable, Equatable {
    case leading
    case center
    case trailing
}

/// テキストレイヤー定義。Codable で保存できるが Rust 側にはレンダ後 RGBA だけ渡す。
struct TextLayerDescriptor: Codable, Equatable {
    /// 表示する文字列
    var text: String
    /// PostScript 名 (Bundle 同梱なら "Inter-Regular" 等。未指定/未解決は system に fallback)
    var fontName: String?
    /// pt 単位
    var fontSize: CGFloat
    /// RGBA 0..1 (アルファは 0..1 のグローバル不透明度)
    var color: [Float]
    /// レイヤー座標系での配置 (左下原点)
    var position: [Float]
    /// 整列
    var alignment: TextLayerAlignment

    init(
        text: String,
        fontName: String? = nil,
        fontSize: CGFloat = 64,
        color: [Float] = [1, 1, 1, 1],
        position: [Float] = [0, 0],
        alignment: TextLayerAlignment = .center
    ) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.position = position
        self.alignment = alignment
    }
}

/// テキストレイヤーをラスタ化するレンダラ。
/// Why: 引数のみで決定論的に CGImage / RGBA バイト列を返すよう、static で副作用なしに保つ。
enum TextLayerRenderer {

    /// `descriptor` を `canvasSize` の透明背景上にレンダして CGImage を返す。
    /// 失敗時 nil。
    static func renderImage(
        descriptor: TextLayerDescriptor,
        canvasSize: CGSize
    ) -> CGImage? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let width = Int(canvasSize.width.rounded())
        let height = Int(canvasSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // 透明背景でクリア
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // フォント解決: 名前指定があれば PostScript 名で取得、無ければ systemFont fallback。
        let font = resolveFont(name: descriptor.fontName, size: descriptor.fontSize)

        let r = CGFloat(descriptor.color.count > 0 ? descriptor.color[0] : 1)
        let g = CGFloat(descriptor.color.count > 1 ? descriptor.color[1] : 1)
        let b = CGFloat(descriptor.color.count > 2 ? descriptor.color[2] : 1)
        let a = CGFloat(descriptor.color.count > 3 ? descriptor.color[3] : 1)
        let textColor = NSColor(srgbRed: r, green: g, blue: b, alpha: a)

        let paragraph = NSMutableParagraphStyle()
        switch descriptor.alignment {
        case .leading: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: descriptor.text, attributes: attributes)

        // Y 軸を反転して通常の左上原点座標系に揃える (Core Text の bottom-left に対応)
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsCtx

        let textSize = attributed.size()
        let originX = CGFloat(descriptor.position[0])
        let originY = CGFloat(descriptor.position[1])
        let drawRect = CGRect(
            x: originX,
            y: originY,
            width: max(textSize.width, 1),
            height: max(textSize.height, 1)
        )
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)

        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }

    /// `renderImage` の RGBA8 バイト列版。Rust 側 `add_layer` (RGBA データ) にそのまま流せる。
    /// - Returns: (rgba bytes, width, height) / 失敗時 nil。
    static func renderRGBA(
        descriptor: TextLayerDescriptor,
        canvasSize: CGSize
    ) -> (Data, Int, Int)? {
        guard let image = renderImage(descriptor: descriptor, canvasSize: canvasSize) else {
            return nil
        }
        let width = image.width
        let height = image.height
        var data = Data(count: width * height * 4)
        let success: Bool = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let baseAddress = ptr.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
        return (data, width, height)
    }

    // MARK: - Helpers

    private static func resolveFont(name: String?, size: CGFloat) -> NSFont {
        if let name, !name.isEmpty,
           let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }
}
