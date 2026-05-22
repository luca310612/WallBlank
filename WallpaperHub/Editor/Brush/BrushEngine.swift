import Foundation

// MARK: - ブラシエンジン ID
// Why: enum + rawValue で型安全に保ちつつ、新規 Engine を追加するときは
// case を 1 つ足すだけで済むよう薄い識別子型として定義する。

/// ブラシエンジンの識別子
enum BrushEngineID: String, Codable, Hashable, CaseIterable {
    case circle      // 円形ハードネスブラシ（既存挙動互換）
    case eraser      // 消しゴム（マスクから減算）
    case airbrush    // エアブラシ（速度・圧力でフロー調整）
    case texture     // テクスチャブラシ（画像テクスチャをスタンプ）
    case smudge      // スマッジ（下地ピクセルを引きずる）

    var displayName: String {
        switch self {
        case .circle:   return "円形ブラシ"
        case .eraser:   return "消しゴム"
        case .airbrush: return "エアブラシ"
        case .texture:  return "テクスチャブラシ"
        case .smudge:   return "スマッジ"
        }
    }
}

// MARK: - 圧力反応モデル
// Why: 各エンジンが「圧力を radius / flow / density / strength / opacity の
// どこにマッピングするか」をデータとして表現する。
// stroke 設定はストローク中 immutable に保つため、Engine は base 値からの
// 倍率を返し、ラスタライズ側 (Phase 1.4) で実際の効果値を計算する。

struct BrushPressureResponse: Equatable {
    /// 半径への倍率（Circle が pressure を反映する経路）
    var radiusMultiplier: CGFloat = 1.0
    /// フローへの倍率（Air）
    var flowMultiplier: CGFloat = 1.0
    /// テクスチャ密度への倍率（Texture）
    var densityMultiplier: CGFloat = 1.0
    /// スマッジ強度への倍率（Smudge）
    var strengthMultiplier: CGFloat = 1.0
    /// 不透明度への倍率（Eraser）
    var opacityMultiplier: CGFloat = 1.0

    /// 圧力非対応サンプルでも安全な「無補正」レスポンス
    static let identity = BrushPressureResponse()
}

// MARK: - ブラシエンジン
// Why: 「ペン種ごとのストローク生成ロジック」を Strategy パターンで分離。
// 入力サンプルの変換とスタンプ位置の生成のみに責務を絞り、
// 実際のラスタ化（Metal/Rust）は外部に委譲する。

/// ブラシエンジンプロトコル
///
/// 実装は基本的にステートレスとし、ストローク中の状態は
/// `BrushStrokeContext` を通じて受け渡しする。
protocol BrushEngine: AnyObject {
    /// 識別子
    var id: BrushEngineID { get }
    /// 表示名（UI 用）
    var displayName: String { get }
    /// 圧力対応の有無（UI のヒント用）
    var supportsPressure: Bool { get }
    /// 傾き対応の有無
    var supportsTilt: Bool { get }

    /// ストローク開始
    /// - Returns: 即座に打つべきスタンプ（通常は始点 1 つ）
    func beginStroke(
        context: inout BrushStrokeContext,
        sample: BrushInputSample
    ) -> [CGPoint]

    /// ストローク継続
    /// - Returns: 直前から今回までに打つべきスタンプ位置
    func continueStroke(
        context: inout BrushStrokeContext,
        sample: BrushInputSample
    ) -> [CGPoint]

    /// ストローク終了
    /// - Returns: 終端で追加するスタンプ（必要なら）
    func endStroke(
        context: inout BrushStrokeContext,
        sample: BrushInputSample
    ) -> [CGPoint]

    /// 入力サンプルの圧力を、各エンジン固有のパラメータ（半径・フロー等）にマップ
    /// - Note: デフォルトは無補正 (`identity`)。pressure 反応を持つエンジンが override する。
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse

    /// 確定ストロークをマスクへ焼く（Phase 1.4 ① Metal 化で本実装）。
    /// - Note: BrushMaskRasterizing が確定するまでは no-op の default 実装でつなぐ。
    func commit(context: BrushStrokeContext, into rasterizer: BrushMaskRasterizing) async
}

// MARK: - 共通ヘルパー
// Why: スタンプ間隔・距離計算など多くの Engine が使うロジックを再利用するため。

extension BrushEngine {
    /// デフォルト: 圧力に反応しない (identity)
    func pressureResponse(for sample: BrushInputSample) -> BrushPressureResponse {
        .identity
    }

    /// デフォルト: ラスタライズ未実装 (Phase 1.4 で本実装に置換)
    func commit(context: BrushStrokeContext, into rasterizer: BrushMaskRasterizing) async {
        // Phase 1.4 で BrushMaskRasterizing が rasterize() を持つようになり次第、
        // 各エンジンは context.stampPoints を rasterizer.rasterize(...) に流し込む。
    }

    /// 2点間距離
    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 2点間を spacing 間隔でスタンプ位置に分解
    /// - Parameters:
    ///   - from: 始点（前回スタンプ位置）
    ///   - to: 終点（今回サンプル位置）
    ///   - spacing: スタンプ間隔（pt）
    ///   - leftover: 前回からの残距離（in/out）
    /// - Returns: 新規に打つべきスタンプ位置
    func stampPositions(
        from: CGPoint,
        to: CGPoint,
        spacing: CGFloat,
        leftover: inout CGFloat
    ) -> [CGPoint] {
        let segmentLength = distance(from, to)
        let totalAvailable = leftover + segmentLength
        guard spacing > 0, totalAvailable >= spacing else {
            leftover = totalAvailable
            return []
        }

        var stamps: [CGPoint] = []
        let dx = (to.x - from.x) / segmentLength
        let dy = (to.y - from.y) / segmentLength

        var traveled = spacing - leftover
        while traveled <= segmentLength {
            let p = CGPoint(x: from.x + dx * traveled, y: from.y + dy * traveled)
            stamps.append(p)
            traveled += spacing
        }
        leftover = segmentLength - (traveled - spacing)
        return stamps
    }
}
