import Foundation
import MetalKit

// MARK: - アニメーションフレーム

/// コマ送りアニメーションの1フレーム
struct AnimationFrame: Codable, Identifiable {
    let id: UUID
    var imagePath: String
    var duration: Double       // フレームの表示時間（秒）

    /// Metalテクスチャ（実行時にロード、非Codable）
    var texture: MTLTexture?

    init(id: UUID = UUID(), imagePath: String, duration: Double = 0.1) {
        self.id = id
        self.imagePath = imagePath
        self.duration = duration
    }

    enum CodingKeys: String, CodingKey {
        case id, imagePath, duration
    }
}

// MARK: - 補間タイプ

/// キーフレーム間の補間方法
enum InterpolationType: String, Codable, CaseIterable {
    case step       // ステップ（瞬間切替）
    case linear     // 線形補間（lerp）
    case easeIn     // イーズイン
    case easeOut    // イーズアウト
    case easeInOut  // イーズインアウト
    case bezier     // 3次ベジェ

    var displayName: String {
        switch self {
        case .step: return "ステップ"
        case .linear: return "リニア"
        case .easeIn: return "イーズイン"
        case .easeOut: return "イーズアウト"
        case .easeInOut: return "イーズインアウト"
        case .bezier: return "ベジェ"
        }
    }

    var icon: String {
        switch self {
        case .step: return "stairs"
        case .linear: return "line.diagonal"
        case .easeIn: return "arrow.up.right"
        case .easeOut: return "arrow.down.right"
        case .easeInOut: return "s.circle"
        case .bezier: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

// MARK: - キーフレーム

/// アニメーションのキーフレーム
struct Keyframe: Codable, Identifiable, Equatable {
    let id: UUID
    var time: Double                 // タイムライン上の時刻（秒）
    var value: Float                 // パラメータ値
    var interpolation: InterpolationType

    init(id: UUID = UUID(), time: Double, value: Float, interpolation: InterpolationType = .linear) {
        self.id = id
        self.time = time
        self.value = value
        self.interpolation = interpolation
    }
}

// MARK: - キーフレームトラック

/// 1つのプロパティに対するキーフレームの集合
struct KeyframeTrack: Codable, Identifiable {
    let id: UUID
    var propertyName: String         // "opacity", "transform.offsetX" 等
    var keyframes: [Keyframe]

    init(id: UUID = UUID(), propertyName: String, keyframes: [Keyframe] = []) {
        self.id = id
        self.propertyName = propertyName
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    /// 指定時刻での補間値を計算
    func evaluate(at time: Double) -> Float {
        guard !keyframes.isEmpty else { return 0 }

        // 最初のキーフレームより前
        if time <= keyframes[0].time {
            return keyframes[0].value
        }

        // 最後のキーフレームより後
        if time >= keyframes[keyframes.count - 1].time {
            return keyframes[keyframes.count - 1].value
        }

        // 前後のキーフレームを検索
        for i in 0..<(keyframes.count - 1) {
            let kf0 = keyframes[i]
            let kf1 = keyframes[i + 1]

            if time >= kf0.time && time <= kf1.time {
                let duration = kf1.time - kf0.time
                guard duration > 0 else { return kf0.value }
                let t = Float((time - kf0.time) / duration)
                let easedT = Interpolation.ease(kf0.interpolation, t: t)
                return Interpolation.lerp(kf0.value, kf1.value, t: easedT)
            }
        }

        return keyframes.last?.value ?? 0
    }

    /// キーフレームを追加（時間順にソート）
    mutating func addKeyframe(_ keyframe: Keyframe) {
        keyframes.append(keyframe)
        keyframes.sort { $0.time < $1.time }
    }

    /// キーフレームを削除
    mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }
}

// MARK: - レイヤーアニメーション

/// レイヤーに紐づくアニメーションデータ
struct LayerAnimation: Codable, Identifiable {
    let id: UUID
    var layerID: UUID                // 対象レイヤーのID
    var tracks: [KeyframeTrack]      // プロパティごとのキーフレームトラック

    init(id: UUID = UUID(), layerID: UUID, tracks: [KeyframeTrack] = []) {
        self.id = id
        self.layerID = layerID
        self.tracks = tracks
    }

    /// プロパティ名でトラックを取得
    func track(for propertyName: String) -> KeyframeTrack? {
        tracks.first { $0.propertyName == propertyName }
    }

    /// プロパティ名でトラックを取得（なければ作成）
    mutating func getOrCreateTrack(for propertyName: String) -> KeyframeTrack {
        if let existing = tracks.first(where: { $0.propertyName == propertyName }) {
            return existing
        }
        let newTrack = KeyframeTrack(propertyName: propertyName)
        tracks.append(newTrack)
        return newTrack
    }

    /// 指定時刻でのLayerTransformを計算
    func evaluateTransform(at time: Double, base: LayerTransform) -> LayerTransform {
        var result = base
        if let t = track(for: "transform.offsetX") { result.offsetX = t.evaluate(at: time) }
        if let t = track(for: "transform.offsetY") { result.offsetY = t.evaluate(at: time) }
        if let t = track(for: "transform.scaleX") { result.scaleX = t.evaluate(at: time) }
        if let t = track(for: "transform.scaleY") { result.scaleY = t.evaluate(at: time) }
        if let t = track(for: "transform.rotation") {
            let targetRotation = t.evaluate(at: time)
            result.rotation = Interpolation.slerp(angle1: base.rotation, angle2: targetRotation, t: 1.0)
        }
        return result
    }

    /// 指定時刻でのImageAdjustmentsを計算
    func evaluateAdjustments(at time: Double, base: ImageAdjustments) -> ImageAdjustments {
        var result = base
        if let t = track(for: "adjustments.brightness") { result.brightness = t.evaluate(at: time) }
        if let t = track(for: "adjustments.contrast") { result.contrast = t.evaluate(at: time) }
        if let t = track(for: "adjustments.saturation") { result.saturation = t.evaluate(at: time) }
        if let t = track(for: "adjustments.temperature") { result.temperature = t.evaluate(at: time) }
        if let t = track(for: "adjustments.exposure") { result.exposure = t.evaluate(at: time) }
        return result
    }

    /// 指定時刻での不透明度を計算
    func evaluateOpacity(at time: Double, base: Float) -> Float {
        track(for: "opacity")?.evaluate(at: time) ?? base
    }
}

// MARK: - 線形代数ユーティリティ

/// 補間計算の数学関数
struct Interpolation {

    /// 線形補間（Linear Interpolation）
    /// result = a + (b - a) * t = a(1-t) + bt
    static func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }

    /// 球面線形補間（Spherical Linear Interpolation）
    /// 回転角度の補間に使用。最短経路で補間する
    static func slerp(angle1: Float, angle2: Float, t: Float) -> Float {
        // 角度差を-π～πに正規化
        var delta = angle2 - angle1
        while delta > Float.pi { delta -= 2 * Float.pi }
        while delta < -Float.pi { delta += 2 * Float.pi }
        return angle1 + delta * t
    }

    /// 3次ベジェ補間
    /// B(t) = (1-t)³p0 + 3(1-t)²t·p1 + 3(1-t)t²·p2 + t³·p3
    static func cubicBezier(p0: Float, p1: Float, p2: Float, p3: Float, t: Float) -> Float {
        let oneMinusT = 1.0 - t
        let oneMinusT2 = oneMinusT * oneMinusT
        let oneMinusT3 = oneMinusT2 * oneMinusT
        let t2 = t * t
        let t3 = t2 * t
        return oneMinusT3 * p0 + 3 * oneMinusT2 * t * p1 + 3 * oneMinusT * t2 * p2 + t3 * p3
    }

    /// 2次ベジェ補間
    /// B(t) = (1-t)²p0 + 2(1-t)t·p1 + t²·p2
    static func quadraticBezier(p0: Float, p1: Float, p2: Float, t: Float) -> Float {
        let oneMinusT = 1.0 - t
        return oneMinusT * oneMinusT * p0 + 2 * oneMinusT * t * p1 + t * t * p2
    }

    /// イージング関数
    /// 補間パラメータtに非線形変換を適用
    static func ease(_ type: InterpolationType, t: Float) -> Float {
        switch type {
        case .step:
            return t < 1.0 ? 0.0 : 1.0

        case .linear:
            return t

        case .easeIn:
            // 3次イーズイン: t³
            return t * t * t

        case .easeOut:
            // 3次イーズアウト: 1 - (1-t)³
            let p = 1.0 - t
            return 1.0 - p * p * p

        case .easeInOut:
            // スムーズステップ: 3t² - 2t³
            return t * t * (3.0 - 2.0 * t)

        case .bezier:
            // デフォルトのベジェカーブ（CSS ease相当）
            // control points: (0.25, 0.1), (0.25, 1.0)
            return cubicBezier(p0: 0, p1: 0.1, p2: 1.0, p3: 1.0, t: t)
        }
    }

    /// LayerTransform全体の補間
    static func interpolateTransform(
        _ a: LayerTransform,
        _ b: LayerTransform,
        t: Float,
        type: InterpolationType = .linear
    ) -> LayerTransform {
        let easedT = ease(type, t: t)
        var result = LayerTransform()
        result.offsetX = lerp(a.offsetX, b.offsetX, t: easedT)
        result.offsetY = lerp(a.offsetY, b.offsetY, t: easedT)
        result.scaleX = lerp(a.scaleX, b.scaleX, t: easedT)
        result.scaleY = lerp(a.scaleY, b.scaleY, t: easedT)
        result.rotation = slerp(angle1: a.rotation, angle2: b.rotation, t: easedT)
        // Bool値はステップ補間（0.5を閾値に切替）
        result.flipHorizontal = easedT < 0.5 ? a.flipHorizontal : b.flipHorizontal
        result.flipVertical = easedT < 0.5 ? a.flipVertical : b.flipVertical
        return result
    }

    /// ImageAdjustments全体の補間
    static func interpolateAdjustments(
        _ a: ImageAdjustments,
        _ b: ImageAdjustments,
        t: Float,
        type: InterpolationType = .linear
    ) -> ImageAdjustments {
        let easedT = ease(type, t: t)
        return ImageAdjustments(
            brightness: lerp(a.brightness, b.brightness, t: easedT),
            contrast: lerp(a.contrast, b.contrast, t: easedT),
            saturation: lerp(a.saturation, b.saturation, t: easedT),
            temperature: lerp(a.temperature, b.temperature, t: easedT),
            sharpness: lerp(a.sharpness, b.sharpness, t: easedT),
            gamma: lerp(a.gamma, b.gamma, t: easedT),
            exposure: lerp(a.exposure, b.exposure, t: easedT)
        )
    }
}
