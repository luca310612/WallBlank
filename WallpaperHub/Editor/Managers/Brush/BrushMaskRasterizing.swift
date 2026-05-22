import Foundation
import CoreGraphics
import Metal

// MARK: - BrushMaskRasterizing
// Why: Phase 1.4+ で Rust 同期実装と Metal compute 実装を Strategy パターンで束ねる中央プロトコル。
// 呼び出し側 (ImageEditorManager / BrushEngine.commit) は実装差を意識せず async で待つ。
// Feature Flag (Settings.useGPUBrush) が OFF の間は RustBrushMaskRasterizer が選ばれ、
// 既存挙動と完全互換となる。

/// 描画対象キャンバスのサイズ (px)。CGSize を使い回す薄い別名。
typealias CanvasSize = CGSize

/// マスクの返却形式。CPU バイト列 or GPU テクスチャを区別して引き渡す。
/// - `cpu`: 既存 SelectionMask 経路に直接流し込める（コピー無し）
/// - `gpu`: ImageEditorManager 等で `getBytes(...)` により CPU 化してから利用する
enum SelectionMaskHandle {
    case cpu(SelectionMask)
    case gpu(MTLTexture)
}

/// マスクラスタライズの中央プロトコル
protocol BrushMaskRasterizing: AnyObject {
    /// ストロークをマスクに焼き込む。
    /// - Parameters:
    ///   - points: キャンバス座標系のストロークサンプル列（最低 2 点）
    ///   - canvas: 描画対象キャンバスサイズ
    ///   - stroke: 半径・硬さ・不透明度等のブラシ設定
    ///   - post: ぼかし・レベル・ノイズ等のポスト処理
    ///   - gradient: グラデーション設定
    ///   - combine: マスク合成モード
    ///   - existing: 既存マスク（差分焼き込み用）
    /// - Returns: 成功時は `.cpu` または `.gpu` ハンドル。失敗時 nil。
    func rasterize(
        points: [CGPoint],
        canvas: CanvasSize,
        stroke: EditorBrushStrokeSettings,
        post: EditorMaskPostSettings,
        gradient: EditorMaskGradientSettings,
        combine: EditorMaskCombineMode,
        existing: SelectionMaskHandle?
    ) async -> SelectionMaskHandle?
}

// MARK: - SelectionMaskHandle 変換ヘルパ

extension SelectionMaskHandle {
    /// `.gpu(MTLTexture)` を `.cpu(SelectionMask)` に正規化する。
    /// - Note: テクスチャは r8Unorm を前提とし、`getBytes(...)` で同期コピーを行う。
    ///   呼び出し回数が多い場合 (フレームごと等) はキャッシュを検討すること。
    func toCPU() -> SelectionMask? {
        switch self {
        case .cpu(let mask):
            return mask
        case .gpu(let texture):
            let width = texture.width
            let height = texture.height
            guard width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height)
            let region = MTLRegionMake2D(0, 0, width, height)
            bytes.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    texture.getBytes(base, bytesPerRow: width, from: region, mipmapLevel: 0)
                }
            }
            return SelectionMask(width: width, height: height, data: bytes)
        }
    }
}
