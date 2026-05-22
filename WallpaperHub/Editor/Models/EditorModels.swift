import Foundation
import MetalKit
import Combine

// MARK: - ブレンドモード

/// レイヤー合成のブレンドモード
enum EditorBlendMode: Int, Codable, CaseIterable {
    case normal = 0       // 通常
    case multiply = 1     // 乗算
    case screen = 2       // スクリーン
    case overlay = 3      // オーバーレイ
    case softLight = 4    // ソフトライト
    case hardLight = 5    // ハードライト
    case add = 6          // 加算
    case subtract = 7     // 減算

    var displayName: String {
        switch self {
        case .normal: return "通常"
        case .multiply: return "乗算"
        case .screen: return "スクリーン"
        case .overlay: return "オーバーレイ"
        case .softLight: return "ソフトライト"
        case .hardLight: return "ハードライト"
        case .add: return "加算"
        case .subtract: return "減算"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "square.on.square"
        case .multiply: return "multiply.circle"
        case .screen: return "sun.max"
        case .overlay: return "square.on.square.intersection.dashed"
        case .softLight: return "light.max"
        case .hardLight: return "bolt.fill"
        case .add: return "plus.circle"
        case .subtract: return "minus.circle"
        }
    }
}

// MARK: - Editor Tools / Selection

/// Photoshop 風のペンサブツール（メインツールが「ペン」のときに使用）
enum PenToolKind: String, Codable, CaseIterable, Identifiable {
    /// なぞって選択（従来のブラシ軌跡）
    case freeform
    /// エッジスナップは将来対応。現状は自由ペンと同じなぞり選択
    case magneticPen
    /// クリックでコーナー、ドラッグでスムーズ点＋対称ハンドル
    case standard
    /// クリックでスムーズ点を主に配置（ハンドルは隣接点から自動算出しつつドラッグで調整可）
    case curvature
    /// 直線のみ（コーナーのみ）。クリック／ドラッグで折れ線
    case polygonal
    /// パス全体をドラッグで移動
    case pathSelect
    /// 1つのアンカーをドラッグで移動
    case directSelect
    /// パス上にアンカーを追加
    case addAnchor
    /// アンカーを削除
    case deleteAnchor
    /// コーナー ⇄ スムーズの切り替え
    case convertPoint

    var id: String { rawValue }

    /// 自由ペン・マグネットなど、ラスタブラシでなぞるモード
    var isFreeformBrushLike: Bool {
        switch self {
        case .freeform, .magneticPen: return true
        default: return false
        }
    }

    /// ベクターパスを編集するモード（パス選択・ダイレクト選択・各種アンカー）
    var isVectorPathTool: Bool {
        switch self {
        case .standard, .curvature, .polygonal, .pathSelect, .directSelect, .addAnchor, .deleteAnchor, .convertPoint:
            return true
        case .freeform, .magneticPen:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .freeform: return "自由ペン"
        case .magneticPen: return "マグネットペン"
        case .standard: return "ペン"
        case .curvature: return "曲率ペン"
        case .polygonal: return "ポリゴンペン"
        case .pathSelect: return "パス選択"
        case .directSelect: return "ダイレクト選択"
        case .addAnchor: return "アンカー追加"
        case .deleteAnchor: return "アンカー削除"
        case .convertPoint: return "アンカー変換"
        }
    }

    var iconSystemName: String {
        switch self {
        case .freeform: return "scribble.variable"
        case .magneticPen: return "lasso.badge.sparkles"
        case .standard: return "pencil.tip"
        case .curvature: return "point.topleft.down.curvedto.point.bottomright.up"
        case .polygonal: return "line.diagonal"
        case .pathSelect: return "arrow.up.left.and.arrow.down.right"
        case .directSelect: return "smallcircle.filled.circle"
        case .addAnchor: return "plus.circle"
        case .deleteAnchor: return "minus.circle"
        case .convertPoint: return "arrow.triangle.2.circlepath"
        }
    }
}

/// エディターのツール（カーソルの役割）
enum EditorTool: String, Codable, CaseIterable {
    case move
    case pen
    case hand
    case zoom
    /// 水流ブラシ: ドラッグ方向に画素を流すベクトル場をペイントする
    case flowBrush

    var displayName: String {
        switch self {
        case .move: return "移動"
        case .pen: return "ペン"
        case .hand: return "ハンド"
        case .zoom: return "ズーム"
        case .flowBrush: return "水流ブラシ"
        }
    }

    var icon: String {
        switch self {
        case .move: return "cursorarrow.motionlines"
        case .pen: return "pencil.tip"
        case .hand: return "hand.raised"
        case .zoom: return "magnifyingglass"
        case .flowBrush: return "drop.fill"
        }
    }
}

/// ペンツールのアンカーポイント（Photoshop 風: コーナー / スムーズ＋対称ハンドル）
struct PenAnchorPoint: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var point: CGPoint
    /// スムーズ点のとき、point からの出方向ハンドル（対称なので入方向は point - offset）
    var outHandleOffset: CGPoint?
    /// true = コーナー（ハンドルなし）、false = スムーズ（ベジェ）
    var isCorner: Bool

    init(id: UUID = UUID(), point: CGPoint, outHandleOffset: CGPoint? = nil, isCorner: Bool = true) {
        self.id = id
        self.point = point
        self.outHandleOffset = outHandleOffset
        self.isCorner = isCorner
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        point = try c.decode(CGPoint.self, forKey: .point)
        outHandleOffset = try c.decodeIfPresent(CGPoint.self, forKey: .outHandleOffset)
        isCorner = try c.decodeIfPresent(Bool.self, forKey: .isCorner) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(point, forKey: .point)
        try c.encodeIfPresent(outHandleOffset, forKey: .outHandleOffset)
        try c.encode(isCorner, forKey: .isCorner)
    }

    private enum CodingKeys: String, CodingKey {
        case id, point, outHandleOffset, isCorner
    }
}

/// ペンで作るパス（キャンバス座標）
struct PenPath: Codable, Equatable {
    var points: [PenAnchorPoint] = []
    var isClosed: Bool = false

    var isEmpty: Bool { points.isEmpty }
    var canClose: Bool { points.count >= 3 }

    /// ベジェ／直線を含む CGPath。`closing` が true のとき最後の点から最初の点へもセグメントを追加
    func cgPath(closing: Bool) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 1 else { return path }
        if points.count == 1 {
            path.move(to: points[0].point)
            return path
        }
        path.move(to: points[0].point)
        let count = points.count
        let segmentCount = closing ? count : count - 1
        for s in 0..<segmentCount {
            let i = s % count
            let j = (s + 1) % count
            let p0 = points[i]
            let p1 = points[j]
            let cp0 = PenPath.controlOut(from: p0)
            let cp1 = PenPath.controlIn(to: p1)
            path.addCurve(to: p1.point, control1: cp0, control2: cp1)
        }
        if closing {
            path.closeSubpath()
        }
        return path
    }

    private static func controlOut(from p: PenAnchorPoint) -> CGPoint {
        if p.isCorner || p.outHandleOffset == nil { return p.point }
        return CGPoint(x: p.point.x + p.outHandleOffset!.x, y: p.point.y + p.outHandleOffset!.y)
    }

    private static func controlIn(to p: PenAnchorPoint) -> CGPoint {
        if p.isCorner || p.outHandleOffset == nil { return p.point }
        return CGPoint(x: p.point.x - p.outHandleOffset!.x, y: p.point.y - p.outHandleOffset!.y)
    }

    /// セグメント上のパラメータ t（0...1）における座標（ベジェまたは直線）
    static func pointOnSegment(from p0: PenAnchorPoint, to p1: PenAnchorPoint, t: CGFloat) -> CGPoint {
        let P0 = p0.point
        let P1 = p1.point
        let C0 = controlOut(from: p0)
        let C1 = controlIn(to: p1)
        let u = 1 - t
        let tt = t * t
        let uu = u * u
        let x = uu * u * P0.x + 3 * uu * t * C0.x + 3 * u * tt * C1.x + tt * t * P1.x
        let y = uu * u * P0.y + 3 * uu * t * C0.y + 3 * u * tt * C1.y + tt * t * P1.y
        return CGPoint(x: x, y: y)
    }
}

/// ラスタ化された選択マスク（キャンバス解像度）
struct SelectionMask: Codable, Equatable {
    var width: Int
    var height: Int
    /// 0 or 255（将来の羽ぼかし対応も視野に入れてUInt8）
    var data: [UInt8]
}

/// 現在の選択状態（MVP: パスと、それをラスタ化したマスク）
struct EditorSelection: Codable, Equatable {
    var penPath: PenPath = .init()
    /// ブラシでなぞった軌跡（キャンバス座標）
    var brushTracePoints: [CGPoint] = []
    /// ブラシ半径（キャンバスピクセル）
    var brushRadius: CGFloat = 20
    var mask: SelectionMask? = nil

    var hasSelection: Bool { mask != nil }
}

// MARK: - レイヤー変形

/// レイヤーの位置・回転・スケール・反転
struct LayerTransform: Codable, Equatable {
    var offsetX: Float = 0       // ピクセル単位のX座標オフセット
    var offsetY: Float = 0       // ピクセル単位のY座標オフセット
    var scaleX: Float = 1        // 横方向スケール
    var scaleY: Float = 1        // 縦方向スケール
    var rotation: Float = 0      // ラジアン単位の回転角
    var flipHorizontal: Bool = false  // 水平反転
    var flipVertical: Bool = false    // 垂直反転

    static let identity = LayerTransform()

    /// 回転角を度数で取得・設定
    var rotationDegrees: Float {
        get { rotation * 180.0 / Float.pi }
        set { rotation = newValue * Float.pi / 180.0 }
    }
}

// MARK: - レイヤー

/// エディターのレイヤー
class EditorLayer: Identifiable, ObservableObject, Codable {
    let id: UUID
    @Published var name: String
    @Published var opacity: Float
    @Published var blendMode: EditorBlendMode
    @Published var isVisible: Bool
    @Published var isLocked: Bool
    @Published var transform: LayerTransform
    @Published var adjustments: ImageAdjustments
    @Published var filterPreset: FilterPreset

    /// 画像ファイルパス（保存用）
    var imagePath: String?

    /// Metalテクスチャ（実行時にロード、非Codable）
    var texture: MTLTexture?

    /// 元画像サイズ
    var imageWidth: Int = 0
    var imageHeight: Int = 0

    /// Rust WGPUエンジン上のレイヤーID（非Codable）
    var rustLayerID: String?

    /// コマ送りフレーム（オプション）
    var frames: [AnimationFrame] = []
    var currentFrameIndex: Int = 0

    // MARK: - 動画レイヤー関連

    /// 動画ファイルパス（保存用）
    var videoPath: String?

    /// 動画メタデータ
    var videoDuration: Double = 0
    var videoFPS: Double = 0
    var videoWidth: Int = 0
    var videoHeight: Int = 0

    /// 動画フレーム抽出エンジン（実行時のみ、非Codable）
    var videoFrameExtractor: VideoFrameExtractor?

    /// 動画レイヤーかどうか
    var isVideoLayer: Bool {
        videoPath != nil
    }

    init(
        id: UUID = UUID(),
        name: String = "新規レイヤー",
        opacity: Float = 1.0,
        blendMode: EditorBlendMode = .normal,
        isVisible: Bool = true,
        isLocked: Bool = false,
        transform: LayerTransform = .identity,
        adjustments: ImageAdjustments = .default,
        filterPreset: FilterPreset = .none
    ) {
        self.id = id
        self.name = name
        self.opacity = opacity
        self.blendMode = blendMode
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.transform = transform
        self.adjustments = adjustments
        self.filterPreset = filterPreset
    }

    /// NSImageからテクスチャをロード
    func loadTexture(from image: NSImage, device: MTLDevice) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            debugLog("[EditorLayer] CGImage変換失敗: \(name)")
            return
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        do {
            texture = try loader.newTexture(cgImage: cgImage, options: options)
            imageWidth = cgImage.width
            imageHeight = cgImage.height
            debugLog("[EditorLayer] テクスチャロード成功: \(name) (\(imageWidth)x\(imageHeight))")
        } catch {
            debugLog("[EditorLayer] テクスチャロード失敗: \(error.localizedDescription)")
        }
    }

    /// ファイルURLからテクスチャをロード
    func loadTexture(from url: URL, device: MTLDevice) {
        guard let image = NSImage(contentsOf: url) else {
            debugLog("[EditorLayer] 画像読み込み失敗: \(url.path)")
            return
        }
        imagePath = url.path
        loadTexture(from: image, device: device)
    }

    /// フレームアニメーション用：現在のフレームテクスチャを取得
    var currentFrameTexture: MTLTexture? {
        // 動画レイヤーの場合: VideoFrameExtractorからオンデマンド取得
        if isVideoLayer, let extractor = videoFrameExtractor {
            let time = extractor.time(forFrame: currentFrameIndex)
            return extractor.frameTexture(at: time) ?? texture
        }

        // コマ送りフレームがある場合
        guard !frames.isEmpty, currentFrameIndex < frames.count else {
            return texture
        }
        return frames[currentFrameIndex].texture ?? texture
    }

    /// レイヤーが有効か（表示中かつテクスチャあり）
    var isActive: Bool {
        isVisible && (texture != nil || !frames.isEmpty || isVideoLayer)
    }

    // MARK: - Codable対応

    enum CodingKeys: String, CodingKey {
        case id, name, opacity, blendMode, isVisible, isLocked
        case transform, adjustments, filterPreset, imagePath
        case imageWidth, imageHeight, frames
        case videoPath, videoDuration, videoFPS, videoWidth, videoHeight
    }

    required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let opacity = try container.decode(Float.self, forKey: .opacity)
        let blendMode = try container.decode(EditorBlendMode.self, forKey: .blendMode)
        let isVisible = try container.decode(Bool.self, forKey: .isVisible)
        let isLocked = try container.decode(Bool.self, forKey: .isLocked)
        let transform = try container.decode(LayerTransform.self, forKey: .transform)
        let adjustments = try container.decode(ImageAdjustments.self, forKey: .adjustments)
        let filterPreset = try container.decode(FilterPreset.self, forKey: .filterPreset)

        self.init(
            id: id, name: name, opacity: opacity, blendMode: blendMode,
            isVisible: isVisible, isLocked: isLocked, transform: transform,
            adjustments: adjustments, filterPreset: filterPreset
        )

        self.imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        self.imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth) ?? 0
        self.imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight) ?? 0
        self.frames = try container.decodeIfPresent([AnimationFrame].self, forKey: .frames) ?? []

        // 動画レイヤー関連
        self.videoPath = try container.decodeIfPresent(String.self, forKey: .videoPath)
        self.videoDuration = try container.decodeIfPresent(Double.self, forKey: .videoDuration) ?? 0
        self.videoFPS = try container.decodeIfPresent(Double.self, forKey: .videoFPS) ?? 0
        self.videoWidth = try container.decodeIfPresent(Int.self, forKey: .videoWidth) ?? 0
        self.videoHeight = try container.decodeIfPresent(Int.self, forKey: .videoHeight) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(blendMode, forKey: .blendMode)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(transform, forKey: .transform)
        try container.encode(adjustments, forKey: .adjustments)
        try container.encode(filterPreset, forKey: .filterPreset)
        try container.encodeIfPresent(imagePath, forKey: .imagePath)
        try container.encode(imageWidth, forKey: .imageWidth)
        try container.encode(imageHeight, forKey: .imageHeight)
        try container.encode(frames, forKey: .frames)

        // 動画レイヤー関連
        try container.encodeIfPresent(videoPath, forKey: .videoPath)
        try container.encode(videoDuration, forKey: .videoDuration)
        try container.encode(videoFPS, forKey: .videoFPS)
        try container.encode(videoWidth, forKey: .videoWidth)
        try container.encode(videoHeight, forKey: .videoHeight)
    }
}

// MARK: - プロジェクト

/// プロジェクトファイルのスキーマバージョン（将来の互換・マイグレーション用）
let kEditorProjectSchemaVersion = 1

/// エディタープロジェクト（レイヤー構成の保存単位）
struct EditorProject: Codable, Identifiable {
    // MARK: - Scene Settings（Wallpaper Engine 風）

    enum SceneResolutionMode: String, Codable, CaseIterable, Identifiable {
        case matchDisplay
        case fixedCanvas
        var id: String { rawValue }
    }

    enum SceneAspectMode: String, Codable, CaseIterable, Identifiable {
        case fit
        case fill
        case stretch
        var id: String { rawValue }
    }

    struct SceneSettings: Codable, Equatable {
        /// “シーン”の想定FPS（タイムラインや時間進行の基準）
        var targetFPS: Double = 60
        /// 時間倍率（0.1…8.0想定）。WGPUのdeltaTime等に掛ける。
        var playbackRate: Double = 1.0
        /// 解像度の基準（ディスプレイ追従 or キャンバス固定）
        var resolutionMode: SceneResolutionMode = .fixedCanvas
        /// アスペクト比の扱い（fit/fill/stretch）
        var aspectMode: SceneAspectMode = .fit
        /// ループ（MVP: タイムライン/全体のループフラグ）
        var loopEnabled: Bool = true
    }

    let id: UUID
    var name: String
    var canvasWidth: Int
    var canvasHeight: Int
    var layers: [EditorLayer]
    var selectedLayerID: UUID?
    var createdAt: Date
    var modifiedAt: Date
    /// プロジェクトファイル形式のバージョン（互換性用、デフォルト1）
    var projectVersion: Int
    /// Wallpaper Engine の “Scene” 相当の設定
    var scene: SceneSettings

    init(
        id: UUID = UUID(),
        name: String = "新規プロジェクト",
        canvasWidth: Int = 1920,
        canvasHeight: Int = 1080,
        layers: [EditorLayer] = [],
        selectedLayerID: UUID? = nil,
        projectVersion: Int = kEditorProjectSchemaVersion,
        scene: SceneSettings = .init()
    ) {
        self.id = id
        self.name = name
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.layers = layers
        self.selectedLayerID = selectedLayerID
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.projectVersion = projectVersion
        self.scene = scene
    }

    /// キャンバスサイズ
    var canvasSize: CGSize {
        CGSize(width: canvasWidth, height: canvasHeight)
    }

    /// 選択中のレイヤーを取得
    var selectedLayer: EditorLayer? {
        guard let id = selectedLayerID else { return nil }
        return layers.first { $0.id == id }
    }

    /// レイヤーのインデックスを取得
    func layerIndex(for id: UUID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, canvasWidth, canvasHeight, layers, selectedLayerID
        case createdAt, modifiedAt, projectVersion
        case scene
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        canvasWidth = try c.decode(Int.self, forKey: .canvasWidth)
        canvasHeight = try c.decode(Int.self, forKey: .canvasHeight)
        layers = try c.decode([EditorLayer].self, forKey: .layers)
        selectedLayerID = try c.decodeIfPresent(UUID.self, forKey: .selectedLayerID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        projectVersion = try c.decodeIfPresent(Int.self, forKey: .projectVersion) ?? kEditorProjectSchemaVersion
        scene = try c.decodeIfPresent(SceneSettings.self, forKey: .scene) ?? .init()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(canvasWidth, forKey: .canvasWidth)
        try c.encode(canvasHeight, forKey: .canvasHeight)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(selectedLayerID, forKey: .selectedLayerID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(projectVersion, forKey: .projectVersion)
        try c.encode(scene, forKey: .scene)
    }
}

// MARK: - Metal Uniforms

/// レイヤー合成用のMetal Uniforms構造体
/// EditorShaders.metalのEditorLayerUniformsと一致させる
struct EditorLayerUniforms {
    // ブレンド設定 (16 bytes)
    var opacity: Float = 1.0
    var blendMode: Int32 = 0
    var _pad0: Float = 0
    var _pad1: Float = 0

    // 変形 (32 bytes)
    var offsetX: Float = 0
    var offsetY: Float = 0
    var scaleX: Float = 1.0
    var scaleY: Float = 1.0
    var rotation: Float = 0
    var flipH: Int32 = 0
    var flipV: Int32 = 0
    var _pad2: Float = 0

    // 画像調整 (32 bytes)
    var brightness: Float = 0
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var temperature: Float = 0
    var sharpness: Float = 0
    var gamma: Float = 1.0
    var exposure: Float = 0
    var filterType: Int32 = 0

    // キャンバス情報 (16 bytes)
    var canvasWidth: Float = 1920
    var canvasHeight: Float = 1080
    var layerWidth: Float = 0
    var layerHeight: Float = 0

    init() {}

    /// EditorLayerから初期化
    init(from layer: EditorLayer, canvasSize: CGSize) {
        // ブレンド
        opacity = layer.opacity
        blendMode = Int32(layer.blendMode.rawValue)

        // 変形
        offsetX = layer.transform.offsetX
        offsetY = layer.transform.offsetY
        scaleX = layer.transform.scaleX
        scaleY = layer.transform.scaleY
        rotation = layer.transform.rotation
        flipH = layer.transform.flipHorizontal ? 1 : 0
        flipV = layer.transform.flipVertical ? 1 : 0

        // 画像調整（フィルタープリセット適用後の値）
        let adj = layer.filterPreset == .none
            ? layer.adjustments
            : layer.filterPreset.adjustments.merged(with: layer.adjustments)
        brightness = adj.brightness
        contrast = adj.contrast
        saturation = adj.saturation
        temperature = adj.temperature
        sharpness = adj.sharpness
        gamma = adj.gamma
        exposure = adj.exposure
        filterType = Int32(layer.filterPreset.rawValue)

        // キャンバス情報
        canvasWidth = Float(canvasSize.width)
        canvasHeight = Float(canvasSize.height)

        // 動画レイヤーの場合は動画解像度を使用
        if layer.isVideoLayer {
            layerWidth = Float(layer.videoWidth)
            layerHeight = Float(layer.videoHeight)
        } else {
            layerWidth = Float(layer.imageWidth)
            layerHeight = Float(layer.imageHeight)
        }
    }
}
