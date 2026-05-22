import Foundation
import SwiftUI
import AVFoundation
import AVKit

// MARK: - Manifest モデル

/// Workshop の音楽プレイヤー型 Web 壁紙の 1 トラック。
/// HTML/JS とは独立に WallBlank 側でネイティブ再生するため、`data.json` を直接モデル化する。
struct MusicTrack: Identifiable, Hashable {
    let id: UUID
    /// 表示用の代表タイトル（ja → ko → fallback の順で解決済み）
    let title: String
    /// 表示用の代表アーティスト
    let artist: String
    /// 楽曲ファイル（プロジェクトルートからの相対パス）
    let musicFileRelative: String
    /// カバー画像（相対パス、無い場合 nil）
    let coverImageRelative: String?
    /// MV（相対パス、無い場合 nil）
    let mvRelative: String?
    /// `default_bg` の番号（`background/bg{NNN}.{ext}` の NNN）
    let defaultBackgroundIndex: Int?
    /// `default` フラグ（プレイリスト初期状態でチェックされるか）
    let isDefault: Bool

    /// 全言語のタイトル（拡張用に保持）
    let titleByLanguage: [String: String]
    let artistByLanguage: [String: String]
    /// 字幕ファイル（言語コード -> 相対パス）
    let subtitleByLanguage: [String: String]
}

/// `data.json` 全体 + 解決済みのバックグラウンド情報を束ねる。
struct MusicWallpaperManifest {
    let rootURL: URL
    let projectTitle: String
    let tracks: [MusicTrack]
    /// `background/bg001.{ext}`, `bg002.{ext}` ... を昇順スキャンした絶対 URL 一覧
    let availableBackgrounds: [URL]

    func track(at index: Int) -> MusicTrack? {
        guard index >= 0 && index < tracks.count else { return nil }
        return tracks[index]
    }

    func musicFileURL(for track: MusicTrack) -> URL {
        rootURL.appendingPathComponent(track.musicFileRelative)
    }

    func coverImageURL(for track: MusicTrack) -> URL? {
        guard let rel = track.coverImageRelative else { return nil }
        return rootURL.appendingPathComponent(rel)
    }

    func mvURL(for track: MusicTrack) -> URL? {
        guard let rel = track.mvRelative else { return nil }
        return rootURL.appendingPathComponent(rel)
    }

    /// `default_bg` 指定があれば対応する背景画像 URL を返す（範囲外なら nil）
    func defaultBackgroundURL(for track: MusicTrack) -> URL? {
        guard let idx = track.defaultBackgroundIndex,
              idx >= 0 && idx < availableBackgrounds.count else { return nil }
        return availableBackgrounds[idx]
    }

    /// 指定言語の字幕ファイル URL を返す（無ければ nil）
    func subtitleURL(for track: MusicTrack, language: String) -> URL? {
        guard let rel = track.subtitleByLanguage[language] else { return nil }
        return rootURL.appendingPathComponent(rel)
    }
}

// MARK: - 字幕エントリ

/// 1 つの字幕行（開始/終了時刻と本文）。SRT を解釈した結果を保持する。
struct SubtitleEntry: Identifiable, Hashable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    /// `<ruby>X<rt>Y</rt></ruby>` を含む生テキスト
    let rawText: String
}

/// 簡易 SRT パーサ。時刻 `HH:MM:SS,mmm` と本文を抽出する。
enum SubtitleParser {
    static func parseSRT(_ source: String) -> [SubtitleEntry] {
        var result: [SubtitleEntry] = []
        // CRLF を LF に正規化、BOM を取り除く
        let normalized = source
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2 else { continue }
            // 1 行目: 番号、2 行目: 時刻範囲、3 行目以降: 本文
            let idxLine = lines[0].trimmingCharacters(in: .whitespaces)
            guard let idx = Int(idxLine) else { continue }
            let timeLine = String(lines[1])
            guard let (start, end) = parseTimeRange(timeLine) else { continue }
            let textLines = lines.dropFirst(2).map { String($0) }
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(SubtitleEntry(id: idx, start: start, end: end, rawText: text))
        }
        return result.sorted { $0.start < $1.start }
    }

    private static func parseTimeRange(_ line: String) -> (TimeInterval, TimeInterval)? {
        // 例: "00:00:06,704 --> 00:00:10,292"
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard let s = parseSrtTime(parts[0]), let e = parseSrtTime(parts[1]) else { return nil }
        return (s, e)
    }

    private static func parseSrtTime(_ raw: String) -> TimeInterval? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        // HH:MM:SS,mmm または HH:MM:SS.mmm
        let normalized = t.replacingOccurrences(of: ",", with: ".")
        let comps = normalized.split(separator: ":")
        guard comps.count == 3 else { return nil }
        guard let h = Double(comps[0]), let m = Double(comps[1]), let s = Double(comps[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// `<ruby>X<rt>Y</rt></ruby>` から本文 X だけ取り出す（ルビ非表示モード用）。
    /// `<rt>...</rt>` 全体を削除し、残った `<ruby>` `</ruby>` タグを取り除く。
    static func stripRuby(_ text: String) -> String {
        var s = text
        // <rt>...</rt> を削除
        while let r = s.range(of: "<rt>"), let e = s.range(of: "</rt>", range: r.upperBound..<s.endIndex) {
            s.removeSubrange(r.lowerBound..<e.upperBound)
        }
        // <ruby> </ruby> タグだけ取り除く
        s = s.replacingOccurrences(of: "<ruby>", with: "")
        s = s.replacingOccurrences(of: "</ruby>", with: "")
        return s
    }

    /// ルビを `本文(よみ)` の形に変換（ネイティブテキスト表示用の簡易代替）。
    static func flattenRubyAsAnnotation(_ text: String) -> String {
        var s = text
        // <ruby>X<rt>Y</rt></ruby> -> X(Y)
        let pattern = #"<ruby>(.*?)<rt>(.*?)</rt></ruby>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1($2)")
        }
        // 念のため残ったタグ除去
        s = s.replacingOccurrences(of: "<ruby>", with: "")
        s = s.replacingOccurrences(of: "</ruby>", with: "")
        return s
    }
}

// MARK: - Detector

/// Workshop の音楽プレイヤー型 Web 壁紙を判定し、Manifest を組み立てる。
///
/// 4 条件:
/// 1. `project.json` の `type == "web"` または `"html"`
/// 2. ルート直下に `data.json` が存在
/// 3. `data.json` がパース可能で配列
/// 4. 配列の各要素に `musicFile` キーがある
/// 5. **追加条件**: project.json に `template == "music-player"` が指定されているか、
///    あるいは workshopid が `musicPlayerWorkshopAllowlist` に含まれていること。
///    （JS 任意実行リスクを抑えるため、デフォルトでは music-player UI を全 Web 壁紙に
///     適用しない。明示的にテンプレ指定された壁紙のみ WallBlank 製ネイティブ UI で描画する）
enum MusicWallpaperDetector {

    /// `project.json` に `template` フィールドが無い既存壁紙のうち、
    /// 公式に music-player テンプレ UI を適用してよい workshopid のホワイトリスト。
    /// 将来的に各壁紙が `project.json` 側に `"template": "music-player"` を持つようになれば
    /// このリストは不要になる。
    private static let musicPlayerWorkshopAllowlist: Set<String> = [
        "3679122549" // 超かぐや姫 All-in-One
    ]

    static func isMusicWallpaper(rootURL: URL) -> Bool {
        loadManifest(rootURL: rootURL) != nil
    }

    static func loadManifest(rootURL: URL) -> MusicWallpaperManifest? {
        let fm = FileManager.default
        guard let canonicalRoot = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: rootURL) else {
            return nil
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // 条件 1: project.json で type == "web"
        let projectURL = canonicalRoot.appendingPathComponent("project.json")
        let projectResolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: projectURL) ?? projectURL
        guard fm.fileExists(atPath: projectResolved.path),
              let projectData = try? Data(contentsOf: projectResolved),
              let projectObj = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any] else {
            return nil
        }
        let typeRaw = (projectObj["type"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard typeRaw == "web" || typeRaw == "html" else { return nil }

        // 条件 5: テンプレ指定されている、または workshopid がホワイトリストに含まれる場合のみ続行。
        // これに該当しない壁紙は、従来通り WKWebView で index.html を表示する経路に戻る。
        let templateRaw = (projectObj["template"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let workshopID = (projectObj["workshopid"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (projectObj["workshopid"] as? Int).map(String.init)
            ?? ""
        let isMusicPlayerTemplate = (templateRaw == "music-player")
            || musicPlayerWorkshopAllowlist.contains(workshopID)
        guard isMusicPlayerTemplate else { return nil }

        // 条件 2: data.json
        let dataURL = canonicalRoot.appendingPathComponent("data.json")
        let dataResolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: dataURL) ?? dataURL
        guard fm.fileExists(atPath: dataResolved.path),
              let raw = try? Data(contentsOf: dataResolved) else {
            return nil
        }

        // 条件 3: 配列パース
        guard let arr = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
            return nil
        }

        // 条件 4: musicFile を持つトラックだけ採用
        let tracks: [MusicTrack] = arr.compactMap { parseTrack(from: $0) }
        guard !tracks.isEmpty else { return nil }

        let backgrounds = enumerateBackgrounds(rootURL: canonicalRoot)
        let title = (projectObj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? canonicalRoot.lastPathComponent

        return MusicWallpaperManifest(
            rootURL: canonicalRoot,
            projectTitle: title,
            tracks: tracks,
            availableBackgrounds: backgrounds
        )
    }

    private static func parseTrack(from dict: [String: Any]) -> MusicTrack? {
        guard let musicFile = (dict["musicFile"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !musicFile.isEmpty else {
            return nil
        }

        let titleByLang = parseLocalizedString(dict["title"])
        let artistByLang = parseLocalizedString(dict["artist"])
        let subtitleByLang = parseLocalizedString(dict["subtitle"])

        let cover = (dict["coverImage"] as? String).flatMap { trimmedOrNil($0) }
        let mv = (dict["mv"] as? String).flatMap { trimmedOrNil($0) }

        let defaultBg: Int?
        if let n = dict["default_bg"] as? Int {
            defaultBg = n
        } else if let n = dict["default_bg"] as? Double {
            defaultBg = Int(n)
        } else if let s = dict["default_bg"] as? String, let n = Int(s) {
            defaultBg = n
        } else {
            defaultBg = nil
        }

        let isDefault: Bool = {
            if let b = dict["default"] as? Bool { return b }
            if let i = dict["default"] as? Int { return i != 0 }
            return false
        }()

        return MusicTrack(
            id: UUID(),
            title: pickRepresentative(from: titleByLang) ?? defaultTitle(fromMusicFile: musicFile),
            artist: pickRepresentative(from: artistByLang) ?? "",
            musicFileRelative: normalizeRelativePath(musicFile),
            coverImageRelative: cover.map { normalizeRelativePath($0) },
            mvRelative: mv.map { normalizeRelativePath($0) },
            defaultBackgroundIndex: defaultBg,
            isDefault: isDefault,
            titleByLanguage: titleByLang,
            artistByLanguage: artistByLang,
            subtitleByLanguage: subtitleByLang
        )
    }

    private static func parseLocalizedString(_ value: Any?) -> [String: String] {
        if let dict = value as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in dict {
                if let s = v as? String, let trimmed = trimmedOrNil(s) {
                    out[k] = trimmed
                }
            }
            return out
        }
        if let s = value as? String, let trimmed = trimmedOrNil(s) {
            return ["": trimmed]
        }
        return [:]
    }

    private static func pickRepresentative(from byLang: [String: String]) -> String? {
        for key in ["ja", "ko", "en", ""] {
            if let v = byLang[key], !v.isEmpty { return v }
        }
        return byLang.values.first
    }

    private static func defaultTitle(fromMusicFile relative: String) -> String {
        let name = (relative as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension
    }

    private static func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func normalizeRelativePath(_ path: String) -> String {
        let unified = path.replacingOccurrences(of: "\\", with: "/")
        return unified.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// `background/bg001.{ext}` を昇順で列挙。連番が途切れたら打ち切る。
    private static func enumerateBackgrounds(rootURL: URL) -> [URL] {
        let bgRoot = rootURL.appendingPathComponent("background")
        let fm = FileManager.default
        let extensions = ["png", "jpg", "jpeg", "webp", "gif"]

        var result: [URL] = []
        var index = 1
        while true {
            let baseName = String(format: "bg%03d", index)
            var found: URL?
            for ext in extensions {
                let candidate = bgRoot.appendingPathComponent("\(baseName).\(ext)")
                let resolved = WallpaperEngineWebResolver.canonicalFilesystemURL(matching: candidate) ?? candidate
                if fm.fileExists(atPath: resolved.path) {
                    found = resolved
                    break
                }
            }
            guard let url = found else { break }
            result.append(url)
            index += 1
            if index > 9999 { break }
        }
        return result
    }
}

// MARK: - Player

/// 音楽プレイヤー型壁紙の再生制御。AVAudioPlayer で音楽、AVPlayer で MV を扱う。
@MainActor
final class MusicWallpaperPlayer: ObservableObject {
    let manifest: MusicWallpaperManifest

    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Float = 0.5 {
        didSet { applyVolume() }
    }
    @Published var isMuted: Bool = false {
        didSet { applyVolume() }
    }

    /// 字幕言語（"ja" / "ko"）。UI から変更されると現在トラックの字幕を再ロードする。
    @Published var subtitleLanguage: String = "ja" {
        didSet {
            guard oldValue != subtitleLanguage else { return }
            reloadSubtitlesForCurrentTrack()
            updateSubtitleEntries()
        }
    }
    /// 現在トラックの字幕全エントリ（字幕ファイルが無いときは空）
    @Published private(set) var subtitleEntries: [SubtitleEntry] = []
    /// 現在再生時刻に対応する字幕エントリ（無いときは nil）
    @Published private(set) var currentSubtitle: SubtitleEntry?
    /// 次に表示される字幕エントリ（次の行のプレビュー用）
    @Published private(set) var nextSubtitle: SubtitleEntry?

    private var audioPlayer: AVAudioPlayer?
    /// MV 表示用 AVPlayer（View から layer に貼るため fileprivate で公開）
    fileprivate var videoPlayer: AVPlayer?
    private var timeObserver: Any?
    private var displayLinkTimer: Timer?

    init(manifest: MusicWallpaperManifest) {
        self.manifest = manifest
        loadTrack(at: 0, autoPlay: false)
    }

    deinit {
        // メインアクター隔離プロパティを deinit で直接触れないため、軽量な後処理だけ行う
        displayLinkTimer?.invalidate()
    }

    var currentTrack: MusicTrack? {
        manifest.track(at: currentIndex)
    }

    /// 現在トラックの背景表示用 URL（MV があればそれ、なければ default_bg）
    var currentBackgroundURL: URL? {
        guard let track = currentTrack else { return nil }
        if let mv = manifest.mvURL(for: track), isPlayableVideo(url: mv) {
            return mv
        }
        return manifest.defaultBackgroundURL(for: track)
    }

    /// 現在トラックの MV URL（再生可能なときだけ返す）
    var currentMVURL: URL? {
        guard let track = currentTrack,
              let mv = manifest.mvURL(for: track),
              isPlayableVideo(url: mv) else { return nil }
        return mv
    }

    /// 現在トラックのカバー画像 URL
    var currentCoverURL: URL? {
        guard let track = currentTrack else { return nil }
        return manifest.coverImageURL(for: track)
    }

    // MARK: 再生制御

    func play() {
        audioPlayer?.play()
        videoPlayer?.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        audioPlayer?.pause()
        videoPlayer?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    /// 壁紙が画面から外されるときに完全停止する。AVAudioPlayer は `stop()` で
    /// 再生位置をリセットし、AVPlayer はカレントアイテムを切り離して音を止める。
    func stop() {
        audioPlayer?.stop()
        videoPlayer?.pause()
        videoPlayer?.replaceCurrentItem(with: nil)
        isPlaying = false
        stopProgressTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        let n = manifest.tracks.count
        guard n > 0 else { return }
        loadTrack(at: (currentIndex + 1) % n, autoPlay: isPlaying)
    }

    func previous() {
        let n = manifest.tracks.count
        guard n > 0 else { return }
        loadTrack(at: (currentIndex - 1 + n) % n, autoPlay: isPlaying)
    }

    func jump(to index: Int) {
        loadTrack(at: index, autoPlay: isPlaying)
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        audioPlayer?.currentTime = clamped
        if let v = videoPlayer {
            v.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        }
        currentTime = clamped
    }

    // MARK: 内部

    private func loadTrack(at index: Int, autoPlay: Bool) {
        guard let track = manifest.track(at: index) else { return }

        // 既存プレイヤーを破棄
        audioPlayer?.stop()
        audioPlayer = nil
        videoPlayer?.pause()
        videoPlayer = nil
        currentTime = 0
        duration = 0

        currentIndex = index

        // 音楽
        let musicURL = manifest.musicFileURL(for: track)
        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.prepareToPlay()
            duration = player.duration
            audioPlayer = player
        } catch {
            debugLog("[MusicWallpaper] AVAudioPlayer 初期化失敗 url=\(musicURL.lastPathComponent) error=\(error)")
        }

        // MV（再生可能なときだけ）
        if let mv = currentMVURL {
            let item = AVPlayerItem(url: mv)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true  // 音は flac から出すので MV は無音再生
            player.actionAtItemEnd = .none
            // 終端ループ
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            videoPlayer = player
        }

        applyVolume()

        // 字幕を現在言語で読み込み（無ければ空配列）
        reloadSubtitlesForCurrentTrack()
        updateSubtitleEntries()

        if autoPlay {
            play()
        }
    }

    private func reloadSubtitlesForCurrentTrack() {
        guard let track = currentTrack,
              let url = manifest.subtitleURL(for: track, language: subtitleLanguage),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            subtitleEntries = []
            currentSubtitle = nil
            nextSubtitle = nil
            return
        }
        subtitleEntries = SubtitleParser.parseSRT(raw)
    }

    /// 現在再生時刻に対応する字幕エントリを更新（タイマーから定期呼出）
    private func updateSubtitleEntries() {
        guard !subtitleEntries.isEmpty else {
            currentSubtitle = nil
            nextSubtitle = nil
            return
        }
        let t = currentTime
        let now = subtitleEntries.first { $0.start <= t && t < $0.end }
        let next = subtitleEntries.first { $0.start > t }
        if currentSubtitle != now { currentSubtitle = now }
        if nextSubtitle != next { nextSubtitle = next }
    }

    private func applyVolume() {
        let v = isMuted ? 0 : volume
        audioPlayer?.volume = v
    }

    private func startProgressTimer() {
        stopProgressTimer()
        displayLinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let p = self.audioPlayer {
                    self.currentTime = p.currentTime
                    self.updateSubtitleEntries()
                    if !p.isPlaying && self.isPlaying {
                        // 自然終了 → 次の曲
                        self.next()
                    }
                }
            }
        }
    }

    private func stopProgressTimer() {
        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
    }

    /// 与えられた webm/mp4/mov などが AVPlayer で再生可能か事前判定。
    /// macOS の AVPlayer は VP8/VP9 webm を再生できない場合がある。
    private func isPlayableVideo(url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return asset.isPlayable
    }
}

// MARK: - SwiftUI View

/// 音楽プレイヤー型壁紙の表示 View。プレビュー / 本番の両方で使う想定。
struct MusicWallpaperView: View {
    let rootURL: URL
    @StateObject private var player: MusicWallpaperPlayer
    @State private var manifestLoaded: Bool = false
    /// 設定 ⚙ ボタンで開閉する右下の設定パネル表示状態
    @State private var showSettingsPanel: Bool = false
    /// ♪ ボタンでプレイヤーカード（左上）を折り畳む
    @State private var playerCollapsed: Bool = false
    /// プレイヤーカバー画像のクリックでプレイリスト表示を切り替える
    @State private var showPlaylist: Bool = true
    /// 字幕ウィジェットの表示状態（CC ボタンで開閉、初期は表示）
    @State private var showSubtitle: Bool = true

    // MARK: 設定パネルの状態（段階1.5: ローカル State でトグル/ステッパーを反応させる）
    enum BackgroundMode { case mvFull, mvSmall, image }
    @State private var bgMode: BackgroundMode = .mvSmall
    @State private var bgSize: Double = 1.0
    @State private var bgXOffset: Int = 0
    @State private var bgYOffset: Int = 0
    @State private var bgMouseAnimation: Bool = false
    @State private var brightness: Int = 50
    @State private var saturation: Int = 60
    @State private var contrast: Int = 60
    @State private var blur: Int = 0
    @State private var useSongDefaultBg: Bool = true
    @State private var showRuby: Bool = true
    @State private var mirrorLayout: Bool = false
    @State private var centerVertically: Bool = false
    @State private var layoutXOffset: Int = 7
    @State private var layoutYOffset: Int = 7
    @State private var globalXOffset: Int = 0
    @State private var globalYOffset: Int = 0
    @State private var smallMVXOffset: Int = 0
    @State private var smallMVYOffset: Int = 0
    @State private var smallMVSize: Double = 1.0
    @State private var visualizerEnabled: Bool = false
    @State private var clock24h: Bool = true
    @State private var clockShowSeconds: Bool = true
    @State private var clockShowTime: Bool = true
    @State private var clockUseJST: Bool = false
    @State private var clockTimeOnTop: Bool = true
    /// 時計表示の 1 秒ごと再描画用ティック
    @State private var clockTick: Date = Date()
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init?(rootURL: URL) {
        self.rootURL = rootURL
        guard let manifest = MusicWallpaperDetector.loadManifest(rootURL: rootURL) else {
            return nil
        }
        _player = StateObject(wrappedValue: MusicWallpaperPlayer(manifest: manifest))
    }

    /// 外部から事前生成した `MusicWallpaperPlayer` を注入する初期化子。
    /// 本番デスクトップ表示では、`DisplayWallpaperInstance` が壁紙切替時に確実に
    /// 音声/MV を停止できるよう Player の参照を保持する必要がある（このクラス内の
    /// `@StateObject` は private で外部から触れないため）。
    init(rootURL: URL, player: MusicWallpaperPlayer) {
        self.rootURL = rootURL
        _player = StateObject(wrappedValue: player)
    }

    var body: some View {
        // 親（プレビュー or 本番ウィンドウ）から与えられたサイズに厳密に収める。
        // SwiftUI の ZStack は子の最大サイズに伸縮するため、GeometryReader で親サイズを取り
        // 明示的な frame + clipped で領域外を切り落とす。
        GeometryReader { proxy in
            // 元 Web UI は 1vh = 画面高/100 を基準にスケールしている。
            // SwiftUI 側でも同じスケール係数で全要素サイズを決め、見た目を一致させる。
            let vh = proxy.size.height / 100.0
            ZStack {
                backgroundLayer
                controlsLayer(size: proxy.size, vh: vh)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .onAppear {
            manifestLoaded = true
        }
    }

    // MARK: 背景

    /// AVPlayer で確実に再生できる動画拡張子（macOS の AVFoundation は VP8/VP9 webm を再生できないことがある）。
    private static let avPlayableVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    @ViewBuilder
    private var backgroundLayer: some View {
        // 全画面を確実に黒で塗ってから動画/画像を重ねる。背景レイヤが nil のとき
        // NSHostingView が透けてデスクトップ壁紙が見えるのを防ぐ。
        ZStack {
            Color.black

            if let mv = player.currentMVURL,
               Self.avPlayableVideoExtensions.contains(mv.pathExtension.lowercased()) {
                MusicWallpaperVideoView(url: mv, attachedPlayer: player)
            } else if let bg = resolvedBackgroundImageURL(),
                      let nsImage = NSImage(contentsOf: bg) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else if let cover = player.currentCoverURL,
                      let nsImage = NSImage(contentsOf: cover) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 30)
                    .overlay(Color.black.opacity(0.4))
            }
        }
    }

    /// 現在トラックの背景画像 URL を解決。`currentBackgroundURL` は MV (webm 含む) を優先するため、
    /// AVPlayer で再生不可能な動画が指定されているときは default_bg にフォールバックする。
    private func resolvedBackgroundImageURL() -> URL? {
        guard let track = player.currentTrack else { return nil }
        return player.manifest.defaultBackgroundURL(for: track)
    }

    // MARK: コントロール

    /// 元 Web UI のレイアウトを再現:
    /// - 上段(top-row): プレイヤーカード + プレイリスト（左寄せ・横並び）
    /// - 下段(bottom-row): 時計カード + 字幕ウィジェット + 設定パネル（左寄せ・横並び、設定は ⚙ で開閉）
    /// 画面の下端から `7vh` 上に下段を、その上に上段を `3vh` あけて配置する。
    /// ZStack + .bottomLeading で下段を確実に画面下に固定し、上段は下段の上方向に積む。
    private func controlsLayer(size: CGSize, vh: CGFloat) -> some View {
        // プレイリストの最大高は「画面高 - 下段高(18vh) - 余白(7vh+3vh) - 上段マージン」で動的に
        let playlistMaxHeight = max(20 * vh, size.height - (7 * vh + 18 * vh + 3 * vh + 3 * vh))

        return ZStack(alignment: .bottomLeading) {
            // 下段（時計 + 字幕 or 設定）
            HStack(alignment: .bottom, spacing: 3 * vh) {
                clockCard(vh: vh)
                if showSubtitle && !showSettingsPanel {
                    subtitleWidget(vh: vh)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
                if showSettingsPanel {
                    settingsPanel(vh: vh)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
                }
            }
            .padding(.leading, 3 * vh)
            .padding(.bottom, 7 * vh)

            // 上段（プレイヤー + プレイリスト）— 下段の上端から 3vh あけて配置
            HStack(alignment: .top, spacing: 3 * vh) {
                if !playerCollapsed {
                    playerCard(vh: vh)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)
                            )
                        )
                }
                if showPlaylist {
                    playlistCard(vh: vh, maxHeight: playlistMaxHeight)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
                }
            }
            .padding(.leading, 3 * vh)
            .padding(.bottom, 7 * vh + 18 * vh + 3 * vh)
        }
        // 元 Web UI と同じ cubic-bezier (0.25, 1, 0.5, 1) 系のなめらかなイージング。
        // 0.4 秒で行き切り、戻りの跳ね返りなしで滑らかに見える。
        .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: playerCollapsed)
        .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: showPlaylist)
        .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: showSettingsPanel)
        .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.4), value: showSubtitle)
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .onReceive(clockTimer) { now in clockTick = now }
    }

    // MARK: プレイヤーカード（左上）

    private func playerCard(vh: CGFloat) -> some View {
        VStack(spacing: 2 * vh) {
            coverImage(vh: vh)

            VStack(spacing: 0.5 * vh) {
                Text(player.currentTrack?.title ?? "")
                    .font(.system(size: 3 * vh, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.system(size: 1.7 * vh))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }

            seekBar(vh: vh)

            HStack(spacing: 0) {
                controlButton(systemName: "shuffle", size: 3 * vh, action: {})
                Spacer()
                controlButton(systemName: "backward.fill", size: 3 * vh, action: player.previous)
                Spacer()
                controlButton(
                    systemName: player.isPlaying ? "pause.fill" : "play.fill",
                    size: 3 * vh,
                    action: player.togglePlayPause
                )
                Spacer()
                controlButton(systemName: "forward.fill", size: 3 * vh, action: player.next)
                Spacer()
                controlButton(systemName: "arrow.clockwise", size: 3 * vh, action: {})
            }

            volumeBar(vh: vh)
        }
        .padding(2.8 * vh)
        .frame(width: 36 * vh)
        .glassCard(cornerRadius: 2.5 * vh)
    }

    @ViewBuilder
    private func coverImage(vh: CGFloat) -> some View {
        Button {
            showPlaylist.toggle()
        } label: {
            ZStack {
                if let cover = player.currentCoverURL,
                   let nsImage = NSImage(contentsOf: cover) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: 30 * vh, height: 30 * vh)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5 * vh))
                } else {
                    RoundedRectangle(cornerRadius: 1.5 * vh)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 30 * vh, height: 30 * vh)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 6 * vh))
                                .foregroundColor(.white.opacity(0.5))
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .help(showPlaylist ? "プレイリストを隠す" : "プレイリストを表示")
    }

    private func controlButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundColor(.white.opacity(0.8))
                .frame(width: size * 1.5, height: size * 1.5)
        }
        .buttonStyle(.plain)
    }

    private func seekBar(vh: CGFloat) -> some View {
        VStack(spacing: 0.5 * vh) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.001)
            )
            .tint(.white)
            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 1.8 * vh).monospacedDigit())
            .foregroundColor(.white.opacity(0.6))
        }
    }

    private func volumeBar(vh: CGFloat) -> some View {
        HStack(spacing: 1.5 * vh) {
            Button(action: { player.isMuted.toggle() }) {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 1.8 * vh))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ),
                in: 0...1
            )
            .tint(.white.opacity(0.8))
        }
    }

    // MARK: プレイリスト（右上）

    private func playlistCard(vh: CGFloat, maxHeight: CGFloat = .infinity) -> some View {
        VStack(alignment: .leading, spacing: 1 * vh) {
            HStack {
                Text("Playlist")
                    .font(.system(size: 1.6 * vh, weight: .light))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                HStack(spacing: 0.5 * vh) {
                    languageButton(label: "JA", code: "ja", vh: vh)
                    languageButton(label: "KO", code: "ko", vh: vh)
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.manifest.tracks.enumerated()), id: \.element.id) { idx, track in
                        playlistRow(idx: idx, track: track, vh: vh)
                    }
                }
            }

            HStack {
                Text("Total Selected Time")
                    .font(.system(size: 1.4 * vh, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text(totalDurationFormatted)
                    .font(.system(size: 1.4 * vh).monospacedDigit())
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(1.5 * vh)
        .frame(width: 36 * vh, height: min(60 * vh, maxHeight))
        .glassCard(cornerRadius: 2.5 * vh)
    }

    private func languageButton(label: String, code: String, vh: CGFloat) -> some View {
        let active = player.subtitleLanguage == code
        return Button {
            player.subtitleLanguage = code
        } label: {
            Text(label)
                .font(.system(size: 1.3 * vh, weight: .light))
                .foregroundColor(active ? .white : .white.opacity(0.5))
                .padding(.horizontal, 0.8 * vh)
                .padding(.vertical, 0.3 * vh)
                .background(
                    RoundedRectangle(cornerRadius: 0.5 * vh)
                        .fill(active ? Color.white.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(idx: Int, track: MusicTrack, vh: CGFloat) -> some View {
        Button {
            player.jump(to: idx)
        } label: {
            HStack(spacing: 1 * vh) {
                if let cover = player.manifest.coverImageURL(for: track),
                   let nsImage = NSImage(contentsOf: cover) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: 4.5 * vh, height: 4.5 * vh)
                        .clipShape(RoundedRectangle(cornerRadius: 0.6 * vh))
                } else {
                    RoundedRectangle(cornerRadius: 0.6 * vh)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 4.5 * vh, height: 4.5 * vh)
                }
                VStack(alignment: .leading, spacing: 0.2 * vh) {
                    Text(track.title)
                        .font(.system(size: 1.5 * vh, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 1.3 * vh, weight: .light))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 0.8 * vh)
            .padding(.vertical, 0.6 * vh)
            .background(
                RoundedRectangle(cornerRadius: 0.8 * vh)
                    .fill(idx == player.currentIndex ? Color.white.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var totalDurationFormatted: String {
        // 段階1: トラック単位の duration をマニフェストから持っていないため、現在曲の duration をプレースホルダ表示
        let total = player.duration
        let totalInt = Int(total)
        return String(format: "%d:%02d", totalInt / 60, totalInt % 60)
    }

    // MARK: 時計カード（左下）

    private func clockCard(vh: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0.5 * vh) {
                if clockTimeOnTop {
                    if clockShowTime { clockTimeText(vh: vh) }
                    clockDateText(vh: vh)
                } else {
                    clockDateText(vh: vh)
                    if clockShowTime { clockTimeText(vh: vh) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 上段アイコン（左: ♪ で プレイヤー折畳、右: ⚙ で設定パネル開閉）
            HStack {
                Button {
                    playerCollapsed.toggle()
                } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 1.8 * vh))
                        .foregroundColor(playerCollapsed ? .white.opacity(0.4) : .white.opacity(0.8))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    showSettingsPanel.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 1.8 * vh))
                        .foregroundColor(showSettingsPanel ? .white : .white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(1.5 * vh)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // 下段アイコン（CC で字幕表示切替）
            HStack {
                Spacer()
                Button {
                    showSubtitle.toggle()
                } label: {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 1.6 * vh))
                        .foregroundColor(showSubtitle ? Color(red: 0.30, green: 0.65, blue: 1.0) : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(1.5 * vh)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(2.5 * vh)
        .frame(width: 36 * vh, height: 18 * vh)
        .glassCard(cornerRadius: 2.5 * vh)
    }

    private func clockTimeText(vh: CGFloat) -> some View {
        Text(currentTimeText)
            .font(.system(size: 6 * vh, weight: .ultraLight).monospacedDigit())
            .foregroundColor(.white)
    }

    private func clockDateText(vh: CGFloat) -> some View {
        Text(currentDateText)
            .font(.system(size: 2.5 * vh, weight: .light))
            .foregroundColor(.white.opacity(0.8))
    }

    private var currentTimeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if clockUseJST { f.timeZone = TimeZone(identifier: "Asia/Tokyo") }
        let pattern = clock24h ? "HH:mm" : "h:mm a"
        f.dateFormat = clockShowSeconds ? pattern.replacingOccurrences(of: "mm", with: "mm:ss") : pattern
        return f.string(from: clockTick)
    }

    private var currentDateText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy. MM. dd. EEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        if clockUseJST { f.timeZone = TimeZone(identifier: "Asia/Tokyo") }
        return f.string(from: clockTick).uppercased()
    }

    // MARK: 字幕ウィジェット（時計カードの右、横長 flex:1 相当）

    private func subtitleWidget(vh: CGFloat) -> some View {
        // 元 UI: current-sub と next-sub を ZStack で重ねて、行が切り替わったら
        // 現在行は上方向にフェードアウト、次行は下から滑り上がってフェードイン。
        // SwiftUI の `.transition(.move)` は加速感が強くカクつきが出やすいので
        // `id` を変えつつ `.opacity` トランジションだけ与え、`AnyTransition.modifier` で
        // CSS 元実装と同じ「offset + opacity + blur」のスムーズな同時アニメに統一する。
        let curText = displayText(player.currentSubtitle?.rawText)
        let nextText = displayText(player.nextSubtitle?.rawText)
        let curID = player.currentSubtitle?.id ?? -1
        let nextID = player.nextSubtitle?.id ?? -2

        let easing = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.5)

        return ZStack {
            // 現在行（中央寄せ・大きく）
            Text(curText.isEmpty ? " " : curText)
                .font(.system(size: 2.5 * vh, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 0.4 * vh, x: 0, y: 0.2 * vh)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .offset(y: -1.5 * vh)
                .id("cur-\(curID)")
                .transition(LyricLineTransition.current(vh: vh))

            // 次行（下・小さく・薄く）
            Text(nextText.isEmpty ? " " : nextText)
                .font(.system(size: 1.8 * vh, weight: .light))
                .foregroundColor(.white.opacity(0.55))
                .shadow(color: .black.opacity(0.5), radius: 0.3 * vh, x: 0, y: 0.1 * vh)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .offset(y: 3.5 * vh)
                .id("next-\(nextID)")
                .transition(LyricLineTransition.next(vh: vh))
        }
        .animation(easing, value: curID)
        .animation(easing, value: nextID)
        .padding(.vertical, 1.5 * vh)
        .padding(.horizontal, 3 * vh)
        .frame(height: 18 * vh)
        .frame(maxWidth: .infinity)
        .clipped()
        .glassCard(cornerRadius: 2.5 * vh)
    }

    /// 字幕本文の表示用文字列を返す。Show Ruby ON ならルビを `本文(よみ)` 形式で残し、
    /// OFF ならルビ部分を取り除いた本文だけを返す。
    private func displayText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return showRuby ? SubtitleParser.flattenRubyAsAnnotation(raw) : SubtitleParser.stripRuby(raw)
    }

    // MARK: 設定パネル（右下、4カラム、⚙ で開閉、State バインド済み）

    private func settingsPanel(vh: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 2 * vh) {
            backgroundColumn(vh: vh)
            settingsDivider(vh: vh)
            selectBgImageColumn(vh: vh)
            settingsDivider(vh: vh)
            layoutColumn(vh: vh)
            settingsDivider(vh: vh)
            effectsClockColumn(vh: vh)
        }
        .padding(2 * vh)
        .frame(height: 60 * vh)
        .glassCard(cornerRadius: 2.5 * vh)
    }

    private func settingsDivider(vh: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1)
    }

    // Background カラム
    private func backgroundColumn(vh: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1.2 * vh) {
            settingsTitle("Background", vh: vh)
            radioRow("MV (Full Screen)", isSelected: bgMode == .mvFull, vh: vh) { bgMode = .mvFull }
            radioRow("MV (Small Window)", isSelected: bgMode == .mvSmall, vh: vh) { bgMode = .mvSmall }
            radioRow("Image", isSelected: bgMode == .image, vh: vh) { bgMode = .image }

            Divider().background(Color.white.opacity(0.1))

            stepperRow(label: "BG Size", text: String(format: "%.2fX", bgSize), vh: vh,
                       onMinus: { bgSize = max(0.5, bgSize - 0.05) },
                       onPlus:  { bgSize = min(3.0, bgSize + 0.05) })
            stepperRow(label: "BG X-Offset", text: "\(bgXOffset)", leftIcon: "arrow.left", rightIcon: "arrow.right", vh: vh,
                       onMinus: { bgXOffset -= 1 }, onPlus: { bgXOffset += 1 })
            stepperRow(label: "BG Y-Offset", text: "\(bgYOffset)", leftIcon: "arrow.down", rightIcon: "arrow.up", vh: vh,
                       onMinus: { bgYOffset -= 1 }, onPlus: { bgYOffset += 1 })

            checkboxRow("BG Mouse Animation", isOn: $bgMouseAnimation, vh: vh)

            Divider().background(Color.white.opacity(0.1))

            Text("FILTER")
                .font(.system(size: 1.3 * vh, weight: .light))
                .foregroundColor(.white.opacity(0.5))
                .tracking(0.5)

            stepperRow(label: "Brightness", text: "\(brightness)", vh: vh,
                       onMinus: { brightness = max(0, brightness - 5) },
                       onPlus:  { brightness = min(200, brightness + 5) })
            stepperRow(label: "Saturation", text: "\(saturation)", vh: vh,
                       onMinus: { saturation = max(0, saturation - 5) },
                       onPlus:  { saturation = min(200, saturation + 5) })
            stepperRow(label: "Contrast", text: "\(contrast)", vh: vh,
                       onMinus: { contrast = max(0, contrast - 5) },
                       onPlus:  { contrast = min(200, contrast + 5) })
            stepperRow(label: "Blur", text: "\(blur)", vh: vh,
                       onMinus: { blur = max(0, blur - 1) },
                       onPlus:  { blur = min(50, blur + 1) })
        }
        .frame(width: 26 * vh, alignment: .leading)
    }

    // Select BG Image カラム
    private func selectBgImageColumn(vh: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1.5 * vh) {
            settingsTitle("Select BG Image", vh: vh)

            HStack(spacing: 1 * vh) {
                Text("User")
                    .font(.system(size: 1.4 * vh))
                    .foregroundColor(.white)
                    .frame(width: 7 * vh, height: 4.5 * vh)
                    .background(
                        RoundedRectangle(cornerRadius: 0.6 * vh)
                            .fill(Color.black.opacity(0.7))
                    )
                RoundedRectangle(cornerRadius: 0.6 * vh)
                    .stroke(Color(red: 0.30, green: 0.65, blue: 1.0).opacity(0.6), lineWidth: 1)
                    .frame(width: 7 * vh, height: 4.5 * vh)
            }

            Spacer(minLength: 0)

            HStack(spacing: 1 * vh) {
                navButton(systemName: "chevron.up", vh: vh) {}
                navButton(systemName: "chevron.down", vh: vh) {}
            }
            HStack(spacing: 1 * vh) {
                navButton(systemName: "chevron.compact.up", vh: vh) {}
                navButton(systemName: "chevron.compact.down", vh: vh) {}
            }

            checkboxRow("Use Song's Default", isOn: $useSongDefaultBg, vh: vh)
        }
        .frame(width: 18 * vh, alignment: .leading)
    }

    private func navButton(systemName: String, vh: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 1.5 * vh))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: 3 * vh)
                .background(
                    RoundedRectangle(cornerRadius: 0.5 * vh)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // Layout カラム
    private func layoutColumn(vh: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1.2 * vh) {
            settingsTitle("Layout", vh: vh)
            checkboxRow("Show Ruby", isOn: $showRuby, vh: vh)
            checkboxRow("Mirror Layout", isOn: $mirrorLayout, vh: vh)
            checkboxRow("Center Vertically", isOn: $centerVertically, vh: vh)

            stepperRow(label: "Layout X-Offset", text: "\(layoutXOffset)", leftIcon: "arrow.left", rightIcon: "arrow.right", vh: vh,
                       onMinus: { layoutXOffset -= 1 }, onPlus: { layoutXOffset += 1 })
            stepperRow(label: "Layout Y-Offset", text: "\(layoutYOffset)", leftIcon: "arrow.down", rightIcon: "arrow.up", vh: vh,
                       onMinus: { layoutYOffset -= 1 }, onPlus: { layoutYOffset += 1 })
            stepperRow(label: "Global X-Offset", text: "\(globalXOffset)", leftIcon: "arrow.left", rightIcon: "arrow.right", vh: vh,
                       onMinus: { globalXOffset -= 1 }, onPlus: { globalXOffset += 1 })
            stepperRow(label: "Global Y-Offset", text: "\(globalYOffset)", leftIcon: "arrow.down", rightIcon: "arrow.up", vh: vh,
                       onMinus: { globalYOffset -= 1 }, onPlus: { globalYOffset += 1 })
            stepperRow(label: "Small MV X-Offset", text: "\(smallMVXOffset)", leftIcon: "arrow.left", rightIcon: "arrow.right", vh: vh,
                       onMinus: { smallMVXOffset -= 1 }, onPlus: { smallMVXOffset += 1 })
            stepperRow(label: "Small MV Y-Offset", text: "\(smallMVYOffset)", leftIcon: "arrow.down", rightIcon: "arrow.up", vh: vh,
                       onMinus: { smallMVYOffset -= 1 }, onPlus: { smallMVYOffset += 1 })
            stepperRow(label: "Small MV Size", text: String(format: "%.2fx", smallMVSize), vh: vh,
                       onMinus: { smallMVSize = max(0.3, smallMVSize - 0.05) },
                       onPlus:  { smallMVSize = min(3.0, smallMVSize + 0.05) })
        }
        .frame(width: 26 * vh, alignment: .leading)
    }

    // Effects & Clock カラム
    private func effectsClockColumn(vh: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1.2 * vh) {
            settingsTitle("Effects & Clock", vh: vh)
            checkboxRow("Visualizer", isOn: $visualizerEnabled, vh: vh)
            checkboxRow("24-Hour Format", isOn: $clock24h, vh: vh)
            checkboxRow("Show Seconds", isOn: $clockShowSeconds, vh: vh)
            checkboxRow("Show Time", isOn: $clockShowTime, vh: vh)
            checkboxRow("Use JST (Tokyo)", isOn: $clockUseJST, vh: vh)
            checkboxRow("Time on Top", isOn: $clockTimeOnTop, vh: vh)

            Spacer(minLength: 0)

            actionButton("Credit", isDestructive: false, vh: vh) {}
            actionButton("Reset Settings", isDestructive: true, vh: vh) { resetAllSettings() }
            actionButton("Force Save", isDestructive: false, vh: vh) {}
        }
        .frame(width: 18 * vh, alignment: .leading)
    }

    private func resetAllSettings() {
        bgMode = .mvSmall
        bgSize = 1.0; bgXOffset = 0; bgYOffset = 0; bgMouseAnimation = false
        brightness = 50; saturation = 60; contrast = 60; blur = 0
        useSongDefaultBg = true
        showRuby = true; mirrorLayout = false; centerVertically = false
        layoutXOffset = 7; layoutYOffset = 7
        globalXOffset = 0; globalYOffset = 0
        smallMVXOffset = 0; smallMVYOffset = 0; smallMVSize = 1.0
        visualizerEnabled = false
        clock24h = true; clockShowSeconds = true; clockShowTime = true
        clockUseJST = false; clockTimeOnTop = true
    }

    // MARK: 共通ミニコンポーネント

    private func settingsTitle(_ text: String, vh: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 1.8 * vh, weight: .light))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func radioRow(_ label: String, isSelected: Bool, vh: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 1 * vh) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    .background(
                        Circle()
                            .fill(isSelected ? Color(red: 0.30, green: 0.65, blue: 1.0) : Color.clear)
                            .padding(0.4 * vh)
                    )
                    .frame(width: 1.6 * vh, height: 1.6 * vh)
                Text(label)
                    .font(.system(size: 1.4 * vh, weight: .light))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private func checkboxRow(_ label: String, isOn: Binding<Bool>, vh: CGFloat) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 1 * vh) {
                ZStack {
                    RoundedRectangle(cornerRadius: 0.3 * vh)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                        .frame(width: 1.6 * vh, height: 1.6 * vh)
                    if isOn.wrappedValue {
                        RoundedRectangle(cornerRadius: 0.3 * vh)
                            .fill(Color(red: 0.30, green: 0.65, blue: 1.0))
                            .frame(width: 1.6 * vh, height: 1.6 * vh)
                        Image(systemName: "checkmark")
                            .font(.system(size: 1.0 * vh, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                Text(label)
                    .font(.system(size: 1.4 * vh, weight: .light))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private func stepperRow(
        label: String,
        text: String,
        leftIcon: String = "minus",
        rightIcon: String = "plus",
        vh: CGFloat,
        onMinus: @escaping () -> Void,
        onPlus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 1 * vh) {
            Text(label)
                .font(.system(size: 1.4 * vh, weight: .light))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0.5 * vh)
            stepperButton(systemName: leftIcon, vh: vh, action: onMinus)
            Text(text)
                .font(.system(size: 1.4 * vh).monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 4.5 * vh)
                .lineLimit(1)
            stepperButton(systemName: rightIcon, vh: vh, action: onPlus)
        }
    }

    private func stepperButton(systemName: String, vh: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 1.2 * vh))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 2.5 * vh, height: 2.5 * vh)
                .background(
                    RoundedRectangle(cornerRadius: 0.5 * vh)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ label: String, isDestructive: Bool, vh: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 1.4 * vh, weight: .light))
                .foregroundColor(isDestructive ? Color(red: 1.0, green: 0.4, blue: 0.4) : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 0.8 * vh)
                .background(
                    RoundedRectangle(cornerRadius: 0.8 * vh)
                        .fill(isDestructive ? Color.red.opacity(0.1) : Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 0.8 * vh)
                                .stroke(isDestructive ? Color.red.opacity(0.4) : Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite && t >= 0 else { return "0:00" }
        let totalSec = Int(t)
        return String(format: "%d:%02d", totalSec / 60, totalSec % 60)
    }
}

// MARK: - ガラス風カード共通スタイル

private extension View {
    /// 元 Web UI の `.glass` スタイル相当（半透明黒地 + 細い白枠）
    func glassCard(cornerRadius: CGFloat) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - 字幕行カスタムトランジション

/// 字幕行のロールアップ風トランジション。
/// `.move(edge:)` の組合せはカクつきが出やすいため、`offset` + `opacity` + `blur`
/// を State 駆動で同時に補間する独自モディファイアを使う。
private struct LyricLineModifier: ViewModifier {
    let yOffset: CGFloat
    let opacity: Double
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blurRadius)
            .offset(y: yOffset)
    }
}

private enum LyricLineTransition {
    /// 現在行: 入場は下から滑り上がり、退場は上方向にフェード+ぼかし
    static func current(vh: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: LyricLineModifier(yOffset: 4 * vh, opacity: 0, blurRadius: 0.4 * vh),
                identity: LyricLineModifier(yOffset: 0, opacity: 1, blurRadius: 0)
            ),
            removal: .modifier(
                active: LyricLineModifier(yOffset: -4 * vh, opacity: 0, blurRadius: 0.4 * vh),
                identity: LyricLineModifier(yOffset: 0, opacity: 1, blurRadius: 0)
            )
        )
    }

    /// 次行: 入場は下から控えめに、退場はその場でフェード
    static func next(vh: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: LyricLineModifier(yOffset: 3 * vh, opacity: 0, blurRadius: 0.3 * vh),
                identity: LyricLineModifier(yOffset: 0, opacity: 1, blurRadius: 0)
            ),
            removal: .modifier(
                active: LyricLineModifier(yOffset: 0, opacity: 0, blurRadius: 0.3 * vh),
                identity: LyricLineModifier(yOffset: 0, opacity: 1, blurRadius: 0)
            )
        )
    }
}

/// AVPlayerLayer を使った MV 表示。SwiftUI から AVPlayer を直接渡せないので NSViewRepresentable で橋渡しする。
private struct MusicWallpaperVideoView: NSViewRepresentable {
    let url: URL
    /// MusicWallpaperPlayer から AVPlayer インスタンスを共有（プレイヤーが再生制御を握る）
    @ObservedObject var attachedPlayer: MusicWallpaperPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        view.playerLayer = layer
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        // attachedPlayer の状態変化（曲送り）に追従する: プレイヤーが持つ AVPlayer を反映
        nsView.playerLayer?.player = attachedPlayer.videoPlayer
    }

    final class PlayerLayerView: NSView {
        var playerLayer: AVPlayerLayer?
    }
}
