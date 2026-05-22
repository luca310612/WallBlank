import Foundation
import Metal
import simd

// MARK: - BrushMaskGPURasterizer
// Why: Phase 1.4 で追加した GPU compute 経路の入口。
// 既存の `BrushMaskRasterizer`（Rust 側で stroke→post-process まで一括処理）はそのまま残し、
// 本クラスは「ストローク中に 1 ダブずつ GPU で塗る」用途を担う。
// MTLTexture(.r8Unorm) を保持し続け、メインスレッド同期描画呼び出しを介さずに
// MTKView 表示・レイヤー合成へそのまま流せる出力を提供する。
//
// 設計上の差分:
// - 1 ダブ = 1 dispatch（Metal kernel `rasterizeDab`）
// - paintMode は normal/add/subtract をサポート（イレーザは subtract）
// - スレッド安全性は MTLCommandQueue 内の serial 実行で担保
// - 既存呼び出し側はノータッチ（本クラスは Phase 1.5 以降で接続予定）

/// ダブ 1 つ分のパラメータ。Metal 側 `DabParams` と完全一致させる。
/// メモリレイアウト: 32バイト (float2 + float + float + float + float + int + int)
struct BrushDabParams {
    var center: SIMD2<Float>
    var radius: Float
    var hardness: Float
    var opacity: Float
    var flow: Float
    var paintMode: Int32
    var _pad0: Int32 = 0
}

/// ペイントモード（Metal kernel 側の定数と対応）
enum BrushDabPaintMode: Int32 {
    case normal   = 0
    case add      = 1
    case subtract = 2
}

/// GPU マスク rasterizer（per-dab）
final class BrushMaskGPURasterizer {

    // MARK: - 依存
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let rasterizePipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState

    // MARK: - 状態
    /// マスクテクスチャ（.r8Unorm）。サイズ変更時は recreate される。
    private(set) var maskTexture: MTLTexture?
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0

    // MARK: - 初期化
    /// - Parameters:
    ///   - device: 共有 MTLDevice。EditorRenderer.metalDevice 等を渡す想定。
    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            print("[BrushMaskGPURasterizer] MTLCommandQueue 生成に失敗")
            return nil
        }
        self.commandQueue = queue

        // デフォルトライブラリから kernel を取得
        guard let library = device.makeDefaultLibrary() else {
            print("[BrushMaskGPURasterizer] makeDefaultLibrary に失敗")
            return nil
        }
        guard
            let rasterizeFn = library.makeFunction(name: "rasterizeDab"),
            let clearFn = library.makeFunction(name: "clearMask")
        else {
            print("[BrushMaskGPURasterizer] kernel 関数取得に失敗 (rasterizeDab/clearMask)")
            return nil
        }
        do {
            self.rasterizePipeline = try device.makeComputePipelineState(function: rasterizeFn)
            self.clearPipeline = try device.makeComputePipelineState(function: clearFn)
        } catch {
            print("[BrushMaskGPURasterizer] パイプライン生成に失敗: \(error)")
            return nil
        }
    }

    // MARK: - テクスチャ確保
    /// 指定サイズでマスクテクスチャを確保（既存とサイズ一致なら再利用）。
    /// - Returns: 成功時は true。失敗時はテクスチャを破棄して false。
    @discardableResult
    func ensureMaskTexture(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        if let tex = maskTexture, tex.width == width, tex.height == height {
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        // Why: Phase 1.4+ で SelectionMaskHandle.gpu → .cpu の読み戻しが必要。
        // Apple Silicon ターゲットでは .shared が unified memory で読み戻し可能 + 高速。
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            print("[BrushMaskGPURasterizer] MTLTexture(.r8Unorm) 生成に失敗 \(width)x\(height)")
            maskTexture = nil
            currentWidth = 0
            currentHeight = 0
            return false
        }
        tex.label = "BrushMask.r8Unorm.\(width)x\(height)"
        maskTexture = tex
        currentWidth = width
        currentHeight = height
        // 確保直後はゼロクリアしておく
        clear()
        return true
    }

    // MARK: - クリア
    /// マスク全体を 0 で塗りつぶす。
    func clear() {
        guard let tex = maskTexture,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder()
        else {
            return
        }
        encoder.label = "BrushMask.clear"
        encoder.setComputePipelineState(clearPipeline)
        encoder.setTexture(tex, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: tex.width, height: tex.height, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        buffer.commit()
    }

    // MARK: - ダブ書き込み（同期）
    /// 1 ダブをマスクへ塗る。
    /// - Note: command buffer の completion を待つので結果テクスチャは即座に表示・合成可能。
    ///   ただし呼び出し元の thread は短時間ブロックする点に注意。
    ///   ストローク中の連続描画では `rasterizeDabAsync` の利用を推奨。
    func rasterizeDab(_ params: BrushDabParams) {
        guard let tex = maskTexture else { return }
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder()
        else {
            return
        }
        encodeDab(params: params, encoder: encoder, mask: tex)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    // MARK: - ダブ書き込み（非同期 / フレーム合流）
    /// 1 ダブを enqueue だけして即時 return する。
    /// ストローク中の連続呼び出しに利用し、UI フレームレートをブロックしない。
    func rasterizeDabAsync(_ params: BrushDabParams, completion: ((MTLTexture?) -> Void)? = nil) {
        guard let tex = maskTexture else {
            completion?(nil)
            return
        }
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder()
        else {
            completion?(nil)
            return
        }
        encodeDab(params: params, encoder: encoder, mask: tex)
        encoder.endEncoding()
        if let completion = completion {
            buffer.addCompletedHandler { _ in
                // GPU 完了後に通知（呼び出し元の thread には依存しない）
                completion(tex)
            }
        }
        buffer.commit()
    }

    // MARK: - 複数ダブをまとめて enqueue
    /// 1 つの command buffer に複数のダブを積む（command buffer overhead を削減）。
    func rasterizeDabsAsync(_ paramsList: [BrushDabParams], completion: ((MTLTexture?) -> Void)? = nil) {
        guard !paramsList.isEmpty else {
            completion?(maskTexture)
            return
        }
        guard let tex = maskTexture else {
            completion?(nil)
            return
        }
        guard let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder()
        else {
            completion?(nil)
            return
        }
        for p in paramsList {
            encodeDab(params: p, encoder: encoder, mask: tex)
        }
        encoder.endEncoding()
        if let completion = completion {
            buffer.addCompletedHandler { _ in completion(tex) }
        }
        buffer.commit()
    }

    // MARK: - 内部: 単一ダブの encode
    private func encodeDab(params: BrushDabParams, encoder: MTLComputeCommandEncoder, mask: MTLTexture) {
        encoder.label = "BrushMask.rasterizeDab"
        encoder.setComputePipelineState(rasterizePipeline)
        encoder.setTexture(mask, index: 0)

        // バッファ経由で DabParams を渡す
        var p = params
        let length = MemoryLayout<BrushDabParams>.stride
        encoder.setBytes(&p, length: length, index: 0)

        // ダブを覆う最小領域を dispatch 対象にする（境界外は kernel 側で早期 return）。
        // radius を ceil で取り、中心から縦横にマージン 1 を加える。
        let radius = max(0.5, CGFloat(params.radius))
        let cx = CGFloat(params.center.x)
        let cy = CGFloat(params.center.y)
        let minX = max(0, Int((cx - radius).rounded(.down)) - 1)
        let minY = max(0, Int((cy - radius).rounded(.down)) - 1)
        let maxX = min(mask.width  - 1, Int((cx + radius).rounded(.up)) + 1)
        let maxY = min(mask.height - 1, Int((cy + radius).rounded(.up)) + 1)
        let regionW = max(0, maxX - minX + 1)
        let regionH = max(0, maxY - minY + 1)
        guard regionW > 0, regionH > 0 else { return }

        // dispatchThreads は thread 起点が 0 のため、領域分の grid をフル発行し、
        // 境界判定は kernel 側に任せる（領域オフセット計算を kernel に渡す方式は将来最適化）。
        // 現時点ではダブ周辺のみ dispatch するため、grid 原点はそのまま (0,0)…(W,H) を使う。
        // ただし全画面を毎ダブ覆うのは無駄なので、原点付近の (regionW x regionH) サイズだけ dispatch する。
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: mask.width, height: mask.height, depth: 1)
        // NOTE: Metal の dispatchThreads は GID 原点を 0 とするため、
        //       「ダブ周辺だけ走らせる」最適化は kernel 側でオフセット bias を受ける形に
        //       将来差し替える。Phase 1.4 ではフル grid + 境界 early return のシンプル実装に留める。
        _ = (minX, minY, regionW, regionH) // 上記 NOTE のため未使用
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
    }
}
