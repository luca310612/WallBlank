import Foundation
import Combine
import AppKit
import AVFoundation
import CoreMedia
import Metal
import IOSurface
import UniformTypeIdentifiers

/// 画像エディターの状態管理マネージャー
class ImageEditorManager: ObservableObject {

    static let shared = ImageEditorManager()

    // MARK: - Published Properties

    @Published var project: EditorProject
    @Published var selectedLayerID: UUID?
    @Published var isModified: Bool = false

    // MARK: - Tool / Selection state（Photoshop風）

    @Published var currentTool: EditorTool = .move
    @Published var selection: EditorSelection = .init()

    /// ブラシ・マスク・パーティクル等のツール一式（UserDefaults 永続化）
    @Published var toolSettings: EditorToolSettings = .load()

    /// Photoshop 風ペンのサブツール（UserDefaults に保存）
    @Published var penToolKind: PenToolKind = .freeform {
        didSet {
            UserDefaults.standard.set(penToolKind.rawValue, forKey: Self.penToolKindUserDefaultsKey)
        }
    }

    static let penToolKindUserDefaultsKey = "artia.editor.penToolKind"

    /// 現在のプロジェクトファイルのURL（一度保存した場合に記録）
    var currentProjectURL: URL?

    /// レンダリングバージョン（毎フレームインクリメントしてSwiftUI再描画をトリガーする）
    @Published var renderVersion: UInt64 = 0

    // MARK: - レンダラー（従来Metal用 — フォールバック）

    let renderer: EditorRenderer?

    // MARK: - WGPU エンジン

    /// Rust WGPUエンジンハンドル
    var wgpuEngine: UnsafeMutableRawPointer?

    /// IOSurface → MTLTexture 変換用
    let metalDevice: MTLDevice?

    /// IOSurfaceから生成したMTLTexture（プレビュー表示用）
    @Published var ioSurfaceTexture: MTLTexture?

    /// IOSurfaceポインタ変更検知用（古いテクスチャを使い続ける問題を防止）
    var lastIOSurfacePtr: UnsafeMutableRawPointer? = nil

    /// 最後に設定したビューポート解像度（draw ループからの重複更新を防ぐ）
    var lastViewportPixelWidth: CGFloat = 0
    var lastViewportPixelHeight: CGFloat = 0

    // MARK: - アニメーション連携

    /// タイムライン自動調整用（ImageEditorViewから設定）
    weak var animationManager: AnimationManager?

    // MARK: - Undo/Redo

    var undoStack: [EditorProjectSnapshot] = []
    var redoStack: [EditorProjectSnapshot] = []
    let maxUndoSteps = 50

    /// Undo/Redo用のプロジェクトスナップショット
    struct EditorProjectSnapshot {
        let projectData: Data
        let description: String
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - デバウンス

    var renderDebounceWorkItem: DispatchWorkItem?
    let renderDebounceInterval: TimeInterval = 0.05

    /// ドラッグ中など即時応答が必要な場合にtrueにする（デバウンスをスキップ）
    /// @Published にして MTKView のリアルタイム描画モードと SwiftUI の updateNSView を同期させる
    @Published var isInteracting: Bool = false

    // MARK: - Add layer dialog（多重起動・連打防止）

    /// レイヤー追加用のOpenPanelが既に表示中か
    var isAddLayerPanelOpen = false
    /// 連打防止用：最後にダイアログを開いた時刻
    var lastAddLayerDialogOpenTime: Date = .distantPast
    let addLayerDialogCooldown: TimeInterval = 0.4

    // MARK: - 非同期レンダリング（インタラクション中）

    /// バックグラウンドレンダリング用キュー
    let renderQueue = DispatchQueue(label: "com.artia.wgpu.render", qos: .userInteractive)
    /// 非同期レンダリングが実行中か
    var asyncRenderInFlight = false
    /// 実行中に新たなレンダリングが要求されたか
    var asyncRenderNeeded = false

    // MARK: - アイドル時更新（長時間放置で画像が固まらないようにする）

    /// エディタキャンバスが表示中か（onAppear/onDisappearで設定）
    @Published var isEditorCanvasVisible: Bool = false
    /// スリープ復帰時の再同期トリガー（EditorCanvasView が .onChange で検知してビューポート再同期）
    @Published var lastWakeTrigger: Date = .distantPast
    /// 放置時も画像を更新するための低頻度タイマー（約1秒ごと）
    var idleRefreshTimer: Timer?
    let idleRefreshInterval: TimeInterval = 1.0

    // MARK: - オートセーブキャッシュ（スリープ/クラッシュ時の復元用）

    /// オートセーブキャッシュファイルURL
    var autosaveCacheURL: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = cacheDir.appendingPathComponent(AppConstants.appFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("editor_autosave.json", isDirectory: false)
    }
    /// オートセーブのデバウンス（動きが止まってから保存）
    var autosaveDebounceWorkItem: DispatchWorkItem?
    let autosaveDebounceInterval: TimeInterval = 1.0
    /// オートセーブの最大サイズ（超えたら書き込まない＝キャッシュ肥大化防止）
    let autosaveMaxDataSize: Int = 50 * 1024 * 1024  // 50MB
    /// キャッシュディレクトリ内の古いファイルを削除する「何日より古いか」
    let cacheStaleDays: Int = 30

    // MARK: - GPU復旧

    /// 連続レンダリング失敗カウンタ
    var consecutiveRenderFailures: Int = 0
    /// 自動リビルドを試みる失敗回数しきい値
    let maxConsecutiveFailuresBeforeRebuild: Int = 3
    /// リビルド中フラグ（再帰防止）
    var isRebuilding: Bool = false

    var cancellables = Set<AnyCancellable>()

    // MARK: - 初期化

    private init() {
        // メインディスプレイのピクセル解像度でキャンバスを初期化
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2.0
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let initW = Int(frame.width * scale)
        let initH = Int(frame.height * scale)
        self.project = EditorProject(canvasWidth: initW, canvasHeight: initH)
        self.renderer = EditorRenderer()
        self.metalDevice = MTLCreateSystemDefaultDevice()

        // オートセーブキャッシュがあれば復元（スリープ/クラッシュからの復帰）
        tryRestoreFromAutosave()

        // WGPUエンジン初期化（復元後のプロジェクトサイズで作成）
        let w = UInt32(project.canvasWidth)
        let h = UInt32(project.canvasHeight)
        self.wgpuEngine = RustCore.createWgpuEngine(width: w, height: h)

        // ビューポートモードはまだ有効化しない（ビューポートサイズ設定後に有効化される）
        // 初期はキャンバスサイズのIOSurfaceでMTLTextureを作成
        if let engine = wgpuEngine {
            updateIOSurfaceTexture(engine: engine)
        }

        // オートセーブ復元時: エンジンにレイヤーを登録
        if !project.layers.isEmpty {
            reloadAllTextures()
            debugLog("[ImageEditorManager] オートセーブ復元: レイヤー \(project.layers.count) 件をエンジンに登録")
        }

        setupWakeObserver()
        cleanupStaleEditorCacheIfNeeded()

        if let raw = UserDefaults.standard.string(forKey: Self.penToolKindUserDefaultsKey),
           let kind = PenToolKind(rawValue: raw) {
            penToolKind = kind
        }

        syncSelectionBrushRadiusFromToolSettings()

        debugLog("[ImageEditorManager] 初期化完了（WGPU統合モード）")
    }

    deinit {
        if let o = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            wakeObserver = nil
        }
        if let o = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            sleepObserver = nil
        }
        if let o = terminateObserver {
            NotificationCenter.default.removeObserver(o)
            terminateObserver = nil
        }
        if let engine = wgpuEngine {
            RustCore.destroyWgpuEngine(engine)
            wgpuEngine = nil
        }
    }

    // MARK: - スリープ復帰

    /// 復帰直後はGPU/表示が不安定なため、キャッシュ再ロードまで待つ時間
    let wakeRestoreDelay: TimeInterval = 1.2

    var wakeObserver: NSObjectProtocol?
    var sleepObserver: NSObjectProtocol?
    var terminateObserver: NSObjectProtocol?



    // MARK: - オートセーブキャッシュ

    /// 変更があるたびにデバウンスしてキャッシュへ保存（動きが止まってから1秒後）

    /// プロジェクトをキャッシュに保存（サイズ上限を超える場合は書き込まない）

    /// 現在のプロジェクト状態をキャッシュに強制書き込み（復帰時の「保存してからリセット」用）

    /// 指定プロジェクトをオートセーブキャッシュに書き込む（共通処理）

    /// キャッシュから復元（アプリ起動時・スリープ後プロセス再起動時）
    /// WGPUエンジン作成前に呼ぶため、テクスチャ再読み込みは後続のinit内で行われる

    /// オートセーブキャッシュを削除（明示的保存・読み込み・新規作成時）

    /// キャッシュディレクトリ内の古いファイルを削除（溜まりすぎ防止）

    // MARK: - WGPU ヘルパー

    /// IOSurfaceからMTLTextureを更新する（ビューポートモード対応）
    /// IOSurfaceポインタが変わった場合のみMTLTextureを再作成する（毎フレーム呼んでも安全）

    // MARK: - ビューポート管理

    /// ビューポートサイズを設定し、IOSurfaceTextureを再作成する（ドローアブルサイズ＝ピクセル単位）
    /// スリープ復帰時に drawableSizeWillChange が不正な小さい値（0や2など）で呼ばれる場合があるため、
    /// 最小サイズ未満の更新は無視する（2x2 で更新すると画像が巨大化して固まるバグを防止）
    /// - Returns: 実際にサイズを更新した場合 true（呼び出し元で再描画を要求する目安）

    /// CanvasViewportの状態をRust WGPUエンジンに同期する（ポイント単位→ピクセル単位変換）

    // MARK: - 選択レイヤー

    /// 現在選択中のレイヤー
    var selectedLayer: EditorLayer? {
        guard let id = selectedLayerID else { return nil }
        return project.layers.first { $0.id == id }
    }

    /// レイヤーを選択

    /// キャンバス座標の点でレイヤーをヒットテスト・選択する

    // MARK: - Selection (Pen → Mask)

    /// ペンパス（キャンバス座標）をキャンバス解像度の選択マスクにラスタ化する

    /// ブラシ軌跡（キャンバス座標）を選択マスクにラスタ化する（`toolSettings` の硬さ・フロー・仕上げを反映）

    /// ブラシ設定をスナップショットしてラスタ化する（ストローク途中の設定変更が過去分に波及しないようにする）

    /// 自由ペン確定時のマスク生成をメインスレッドでブロックしない（処理は直列キューで順序維持）
    static let selectionMaskRasterQueue = DispatchQueue(label: "artia.editor.selectionMaskRaster", qos: .userInitiated)


    /// マグネットペン: GPU からの RGBA 取得後の CPU 処理をバックグラウンドへ（取得のみメイン）

    /// ツール設定を更新して保存し、プレビュー用の `selection.brushRadius` を同期する


    /// 自由ペン（なぞり）確定済みストロークの輪郭（プレビュー用）
    @Published var freeformBrushCompletedOutlines: [[CGPoint]] = []



    /// マーチングアンツ用の輪郭プレビューのみ消去（選択マスクはそのまま）

    // MARK: - Vector Pen（Photoshop 風パス選択）

    /// ベクターパスをクリア（自由ペン軌跡もリセット）


    /// 曲率ペン: クリックのみでスムーズ点を追加（隣接方向からハンドル長を推定）

    /// 始点付近をクリックでパスを閉じて選択マスク化

    /// パス上の全アンカーをキャンバス座標で平行移動（パス選択ツール用）

    /// ダイレクト選択: 指定アンカーを移動

    /// Return キー等: パスを閉じて選択マスク化



    /// ベクターペン: 未閉じパスなら最後のアンカーを削除（Delete / Forward Delete）


    /// 最も近いセグメント上にコーナーアンカーを挿入


    // MARK: - Selection → Layer

    /// 選択範囲を新規レイヤーにコピー（Cmd+J）

    /// 選択範囲を新規レイヤーに切り取り（Shift+Cmd+J）

    enum SelectionMaskApplyMode {
        case keepInside
        case clearInside
    }

    /// RGBA(キャンバスサイズ)に選択マスクを適用する（処理本体は Rust `artia_core::magnetic_select`）

    // MARK: - レイヤー操作

    /// 画像からレイヤーを追加

    /// ファイルURLからレイヤーを追加

    /// レイヤーの画像解像度からキャンバスにフィットするtransformを計算して設定する
    /// Rust側ではscale=1.0で画像の元ピクセルサイズが表示されるため、
    /// キャンバスに収まるようscaleを計算して設定する

    /// NSImageをRGBA8バイト列に変換する

    // MARK: - マグネットペン（色近傍オート選択）

    /// 現在のキャンバス合成結果をRGBAで取得する（キャンバス解像度）

    /// マグネットペン用。線上の色をサンプルして、近い色の連結領域を自動選択マスクにする。
    /// - Note: `tolerance01` は 0...1（RGB距離の許容）。大きいほど広く選択される。

    /// 合成 RGBA スナップショットからマスクのみ計算（任意スレッド可）。処理本体は Rust。


    /// 指定サイズの透明RGBAデータを生成（レイヤー複製時のフォールバック用）

    // MARK: - 動画レイヤー操作

    /// 動画ファイルからレイヤーを追加

    /// VideoFrameExtractorの動画から先頭フレームのRGBAバイト列を取得する

    /// CGImageをRGBA8バイト列に変換する

    /// 複数のファイルからレイヤーを追加（画像・動画を自動判別）

    /// レイヤーを削除

    /// レイヤーを移動

    /// レイヤーを複製

    /// 選択レイヤーを下のレイヤーと結合

    // MARK: - レイヤープロパティ変更

    /// 不透明度変更のUndoスナップショットをデバウンス管理する
    var opacityUndoWorkItem: DispatchWorkItem?
    var hasOpacityUndoSnapshot = false

    /// 不透明度を変更

    /// ブレンドモードを変更

    /// 表示/非表示を切り替え

    /// ロック/アンロックを切り替え

    /// 画像調整変更のUndoデバウンス管理
    var adjustmentsUndoWorkItem: DispatchWorkItem?
    var hasAdjustmentsUndoSnapshot = false

    /// 画像調整を変更

    /// フィルタープリセットを適用

    /// 変形変更のUndoデバウンス管理
    var transformUndoWorkItem: DispatchWorkItem?
    var hasTransformUndoSnapshot = false

    /// 変形を変更

    /// インタラクション終了時に最終同期＋Undoフラグリセット

    // MARK: - レンダリング

    /// インタラクション中に MTKView の draw から呼ぶ。最新の transform を Rust に同期して即レンダーし、画像をオーバーレイと同じタイミングで動かす。
    /// - Parameter bumpRenderVersion: true のときだけ SwiftUI 全体を無駄に巻き込まないよう通常は false（表示は MTKView の連続 draw に任せる）

    /// ネストした @Published（selection 内の配列など）更新後にオーバーレイだけ即再描画したいとき

    /// レンダリング要求（インタラクション中はdraw側で同期レンダー、それ以外はデバウンス）

    /// 同期レンダリング（非インタラクション時・復旧時）

    /// 非同期レンダリングをスケジュール（インタラクション中）
    /// アウトラインはSwiftUI側で即座に更新され、画像レンダリングはバックグラウンドで追従する


    /// エディタキャンバスの表示状態を設定する（View の onAppear/onDisappear から呼ぶ）
    /// 表示中は低頻度でレンダリングして長時間放置時の画像固まりを防ぐ



    /// スリープ復帰やウィンドウ再フォーカス時に呼ぶ。IOSurface を再バインドして 1 回レンダーする

    /// GPUデバイスロストからの復旧（エンジン再構築 + 全テクスチャ再ロード）

    // MARK: - Undo/Redo

    /// Undoスナップショットを保存

    /// Undo実行

    /// Redo実行

    /// 全レイヤーのテクスチャを再ロード（WGPUエンジンも再構築）

    /// マスクエディターのマスクを WGPU キャンバスマスクに反映する（解像度はキャンバスと一致していること）

    /// Swift の project.layers 順（下＝背面 → 上＝前面）を Rust の合成順と強制一致させる

    /// WGPUエンジンを再作成する

    /// レイヤーのプロパティをRust側に同期する

    /// ImageAdjustmentsをJSON文字列に変換する

    /// LayerTransformをEditorTransform形式のJSON文字列に変換する

    // MARK: - プロジェクト保存/読み込み

    /// プロジェクトファイルのディレクトリを基準に相対パスに変換（同一ディレクトリ以下なら相対、それ以外はそのまま）

    /// 相対パスをプロジェクトディレクトリ基準で絶対パスに解決

    /// `.artia` パッケージ（ディレクトリ）かどうか

    /// プロジェクトをファイルに保存。`.artia` の場合はパッケージ（project.json + assets/）として書き出す。

    /// 保存しないで閉じたとき: オートセーブ・エディター用一時ファイルを削除し、空プロジェクトに戻す


    /// 上書き保存（保存先が未設定の場合は保存ダイアログを表示）

    /// ウィンドウを閉じる前の保存確認ダイアログ
    /// - Returns: true = 閉じてOK, false = キャンセル

    /// プロジェクトをファイルから読み込み（相対パスはプロジェクトファイルのディレクトリ基準で解決）

    /// 新規プロジェクト（デフォルトでメインディスプレイの解像度を使用）

    // MARK: - Workshop 用エクスポート

    /// Workshop 用に 1 フォルダを組み立てる（project.json + assets/ + preview.jpg）。Steam 非依存。
    /// - Parameter folderURL: 出力先フォルダ（存在する空フォルダ、または新規作成される）

    /// Workshop 用エクスポートのフォルダ選択ダイアログを表示

    /// Workshop に投稿するダイアログを表示（Steam 未接続時は案内、接続時はアップロード実行）

    // MARK: - エクスポート

    /// 合成結果をNSImageとしてエクスポート（キャンバスサイズで出力）

    /// RGBAバイト列をNSImageに変換する

    /// 合成結果をWallpaperEngineに適用

    // MARK: - ファイル選択ダイアログ

    /// ファイル選択ダイアログを表示してレイヤー追加（多重起動・連打防止あり）

    /// プロジェクト保存ダイアログ

    /// プロジェクト読み込みダイアログ
}

// MARK: - Array安全アクセス

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension UTType {
    /// WallBlank エディター用ドキュメントパッケージ（ディレクトリ `.artia` + project.json + assets）
    static var artiaWallpaperProject: UTType {
        UTType(exportedAs: "com.artia.artia-package")
    }
}
