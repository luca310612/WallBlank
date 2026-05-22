// 水流ブラシマネージャ
// レイヤー上にドラッグでベクトル場を描き、画素を流すように見せる
//
// 使い方:
// 1. beginStroke(layerId:) でストローク開始
// 2. addPoint(_:) でドラッグ中の点を追加（NSViewのマウスイベントから呼ぶ）
// 3. endStroke() でフラッシュ
// 4. setEnabled(layerId:enabled:) で有効化（または paint で自動有効化）
//
// パラメータ:
// - radius: ピクセル単位のブラシ半径
// - strength: 流速（UV空間/秒、0.05〜0.5 推奨）
// - softness: フォールオフ（0.05〜1.0、大きいほど中心集中）
// - loopDuration: フェードクロスループ周期（秒、デフォルト2.0）
// - speedScale: 速度全体倍率（デフォルト0.15）

import Foundation
import Combine

@MainActor
final class FlowBrushManager: ObservableObject {
    static let shared = FlowBrushManager()

    // MARK: - 公開プロパティ（ツールパネルからバインドされる）

    /// ブラシ半径（ピクセル）
    @Published var radius: Float = 80.0
    /// ストロークの流速（UV/秒）
    @Published var strength: Float = 0.35
    /// フォールオフ（中心集中度）
    @Published var softness: Float = 0.5
    /// ループ周期（秒）
    @Published var loopDuration: Float = 2.0
    /// 速度倍率（フィールド全体の強さ）
    @Published var speedScale: Float = 0.15
    /// 水流ブラシモードがアクティブか
    @Published var isActive: Bool = false

    // MARK: - 内部状態

    /// 現在ストローク中のレイヤーID（Rust側ID）
    private var currentLayerId: String?
    /// ストローク中の点列
    private var pendingPoints: [RustCore.FlowStrokePoint] = []
    /// 直前にRustへフラッシュした点までのインデックス
    private var lastFlushedIndex: Int = 0

    private init() {}

    // MARK: - ストローク制御

    /// ストロークを開始する
    /// - Parameter layerId: 対象レイヤーのRust側ID
    func beginStroke(layerId: String) {
        currentLayerId = layerId
        pendingPoints.removeAll(keepingCapacity: true)
        lastFlushedIndex = 0
    }

    /// ストローク中に点を追加し、必要ならRustへ部分フラッシュする
    /// - Parameter point: レイヤー画像座標系の点
    func addPoint(_ point: CGPoint) {
        guard currentLayerId != nil else { return }
        let p = RustCore.FlowStrokePoint(x: Float(point.x), y: Float(point.y))
        pendingPoints.append(p)

        // 一定数たまったら部分フラッシュ（インクリメンタル反映で見た目の追従性UP）
        if pendingPoints.count - lastFlushedIndex >= 8 {
            flush(partial: true)
        }
    }

    /// ストロークを終了し、残りをフラッシュする
    func endStroke() {
        flush(partial: false)
        currentLayerId = nil
        pendingPoints.removeAll(keepingCapacity: false)
        lastFlushedIndex = 0
    }

    /// 現在のストロークを中断する（フラッシュしない）
    func cancelStroke() {
        currentLayerId = nil
        pendingPoints.removeAll(keepingCapacity: false)
        lastFlushedIndex = 0
    }

    // MARK: - 単発操作

    /// 指定レイヤーのフローフィールドを完全クリアする
    @discardableResult
    func clear(layerId: String) -> Bool {
        guard let engine = ImageEditorManager.shared.wgpuEngine else {
            print("[FlowBrush] エンジン未初期化")
            return false
        }
        return RustCore.wgpuClearFlowField(engine, layerId: layerId)
    }

    /// 指定レイヤーのフローを有効/無効にし、現在のループ設定を反映する
    @discardableResult
    func setEnabled(layerId: String, enabled: Bool) -> Bool {
        guard let engine = ImageEditorManager.shared.wgpuEngine else {
            return false
        }
        return RustCore.wgpuSetFlowParams(
            engine,
            layerId: layerId,
            enabled: enabled,
            loopDuration: loopDuration,
            speedScale: speedScale
        )
    }

    /// ループ周期・速度倍率の変更を即座に反映する
    @discardableResult
    func applyParams(layerId: String) -> Bool {
        return setEnabled(layerId: layerId, enabled: true)
    }

    // MARK: - 内部: フラッシュ

    /// 蓄積した点をRustへ送り、ベクトル場へ反映する
    private func flush(partial: Bool) {
        guard let layerId = currentLayerId,
              let engine = ImageEditorManager.shared.wgpuEngine else {
            return
        }
        let total = pendingPoints.count
        guard lastFlushedIndex < total else { return }

        // 部分フラッシュ時は方向検出のため直前の点も含めて送る（最低2点必要）
        let startIdx = max(0, lastFlushedIndex - 1)
        let slice = Array(pendingPoints[startIdx..<total])
        guard slice.count >= 1 else { return }

        let params = RustCore.FlowBrushParams(
            radius: radius,
            strength: strength,
            softness: softness
        )
        RustCore.wgpuPaintFlowStroke(
            engine,
            layerId: layerId,
            points: slice,
            params: params
        )
        lastFlushedIndex = total

        // ストローク終了時はフロー有効化＋ループ設定も反映
        if !partial {
            RustCore.wgpuSetFlowParams(
                engine,
                layerId: layerId,
                enabled: true,
                loopDuration: loopDuration,
                speedScale: speedScale
            )
        }
    }
}
