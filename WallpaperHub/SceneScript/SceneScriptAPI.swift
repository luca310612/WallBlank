import Foundation
import JavaScriptCore

// MARK: - JSExport プロトコル

/// JS 側に公開する `engine` global。
@objc public protocol SceneScriptEngineAPIExport: JSExport {
    func time() -> Double
    func random() -> Double
    func log(_ message: Any)
    func setLayerProperty(_ layerId: String, _ key: String, _ value: Any)
}

/// JS 側に公開する `layer(id)` ファクトリの返り値。
@objc public protocol SceneScriptLayerHandleExport: JSExport {
    func setOpacity(_ value: Double)
    func setColor(_ r: Double, _ g: Double, _ b: Double)
    func setScale(_ s: Double)
    func setPosition(_ x: Double, _ y: Double)
    func setRotation(_ degrees: Double)
}

/// JS 側に公開する `sound(id)` ファクトリの返り値。
@objc public protocol SceneScriptSoundHandleExport: JSExport {
    func play()
    func pause()
    func volume(_ v: Double)
}

/// JS 側に公開する `video(id)` ファクトリの返り値。
@objc public protocol SceneScriptVideoHandleExport: JSExport {
    func play()
    func pause()
    func seek(_ t: Double)
}

/// JS 側に公開する `particles(id)` ファクトリの返り値。
@objc public protocol SceneScriptParticlesHandleExport: JSExport {
    func setEmitterRate(_ rate: Double)
    func setEmitterPosition(_ x: Double, _ y: Double)
}

// MARK: - Backend プロトコル
// Why: WgpuEngine / VideoWallpaperRuntime / ParticleSystemBridge を直接依存させずに
//      テスト時 mock 差し替え可能にするため、薄い protocol を切る。

/// レイヤー操作を委譲する backend。
public protocol SceneScriptLayerBackend: AnyObject {
    func setLayerOpacity(layerId: String, opacity: Float)
    func setLayerColor(layerId: String, r: Float, g: Float, b: Float)
    func setLayerScale(layerId: String, scale: Float)
    func setLayerPosition(layerId: String, x: Float, y: Float)
    func setLayerRotation(layerId: String, degrees: Float)
    /// 任意 key/value 操作。WARN ログを出すか否かは backend に委ねる。
    func setLayerProperty(layerId: String, key: String, value: Any)
}

/// サウンド操作 backend (Phase 6A 前は no-op で良い)。
public protocol SceneScriptSoundBackend: AnyObject {
    func play(soundId: String)
    func pause(soundId: String)
    func setVolume(soundId: String, volume: Float)
}

/// ビデオ操作 backend。
public protocol SceneScriptVideoBackend: AnyObject {
    func play(videoId: String)
    func pause(videoId: String)
    func seek(videoId: String, time: Double)
}

/// パーティクル操作 backend。
public protocol SceneScriptParticlesBackend: AnyObject {
    func setEmitterRate(systemId: String, rate: Float)
    func setEmitterPosition(systemId: String, x: Float, y: Float)
}

/// log メッセージ集約用。テストで受信確認するため protocol を切る。
public protocol SceneScriptLogSink: AnyObject {
    func receive(message: String)
}

// MARK: - 既定 (no-op) backend

public final class NoopSceneScriptBackends: SceneScriptLayerBackend,
    SceneScriptSoundBackend,
    SceneScriptVideoBackend,
    SceneScriptParticlesBackend,
    SceneScriptLogSink {

    public init() {}

    public func setLayerOpacity(layerId: String, opacity: Float) {}
    public func setLayerColor(layerId: String, r: Float, g: Float, b: Float) {}
    public func setLayerScale(layerId: String, scale: Float) {}
    public func setLayerPosition(layerId: String, x: Float, y: Float) {}
    public func setLayerRotation(layerId: String, degrees: Float) {}
    public func setLayerProperty(layerId: String, key: String, value: Any) {
        NSLog("[SceneScript] WARN setLayerProperty 未対応: %@.%@", layerId, key)
    }

    public func play(soundId: String) {}
    public func pause(soundId: String) {}
    public func setVolume(soundId: String, volume: Float) {}

    public func play(videoId: String) {}
    public func pause(videoId: String) {}
    public func seek(videoId: String, time: Double) {}

    public func setEmitterRate(systemId: String, rate: Float) {}
    public func setEmitterPosition(systemId: String, x: Float, y: Float) {}

    public func receive(message: String) {
        NSLog("[SceneScript] %@", message)
    }
}

// MARK: - JSExport 実装

/// `engine` global の実体。
@objc public final class SceneScriptEngineAPI: NSObject, SceneScriptEngineAPIExport {
    private let layerBackend: SceneScriptLayerBackend
    private let logSink: SceneScriptLogSink
    private let startedAt: Date
    /// テスト容易化のため乱数を差し替え可能 (デフォルトは drand48)。
    private let randomProvider: () -> Double

    public init(layerBackend: SceneScriptLayerBackend,
                logSink: SceneScriptLogSink,
                randomProvider: @escaping () -> Double = { drand48() }) {
        self.layerBackend = layerBackend
        self.logSink = logSink
        self.startedAt = Date()
        self.randomProvider = randomProvider
    }

    public func time() -> Double {
        return Date().timeIntervalSince(startedAt)
    }

    public func random() -> Double {
        return randomProvider()
    }

    public func log(_ message: Any) {
        logSink.receive(message: SceneScriptEngineAPI.stringify(message))
    }

    public func setLayerProperty(_ layerId: String, _ key: String, _ value: Any) {
        layerBackend.setLayerProperty(layerId: layerId, key: key, value: value)
    }

    /// JS 側から渡された Any (NSString / NSNumber / NSNull など) を文字列化する。
    static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return String(describing: value)
    }
}

@objc public final class SceneScriptLayerHandle: NSObject, SceneScriptLayerHandleExport {
    private let layerId: String
    private let backend: SceneScriptLayerBackend

    public init(layerId: String, backend: SceneScriptLayerBackend) {
        self.layerId = layerId
        self.backend = backend
    }

    public func setOpacity(_ value: Double) {
        backend.setLayerOpacity(layerId: layerId, opacity: Float(value))
    }
    public func setColor(_ r: Double, _ g: Double, _ b: Double) {
        backend.setLayerColor(layerId: layerId, r: Float(r), g: Float(g), b: Float(b))
    }
    public func setScale(_ s: Double) {
        backend.setLayerScale(layerId: layerId, scale: Float(s))
    }
    public func setPosition(_ x: Double, _ y: Double) {
        backend.setLayerPosition(layerId: layerId, x: Float(x), y: Float(y))
    }
    public func setRotation(_ degrees: Double) {
        backend.setLayerRotation(layerId: layerId, degrees: Float(degrees))
    }
}

@objc public final class SceneScriptSoundHandle: NSObject, SceneScriptSoundHandleExport {
    private let soundId: String
    private let backend: SceneScriptSoundBackend
    public init(soundId: String, backend: SceneScriptSoundBackend) {
        self.soundId = soundId
        self.backend = backend
    }
    public func play() { backend.play(soundId: soundId) }
    public func pause() { backend.pause(soundId: soundId) }
    public func volume(_ v: Double) { backend.setVolume(soundId: soundId, volume: Float(v)) }
}

@objc public final class SceneScriptVideoHandle: NSObject, SceneScriptVideoHandleExport {
    private let videoId: String
    private let backend: SceneScriptVideoBackend
    public init(videoId: String, backend: SceneScriptVideoBackend) {
        self.videoId = videoId
        self.backend = backend
    }
    public func play() { backend.play(videoId: videoId) }
    public func pause() { backend.pause(videoId: videoId) }
    public func seek(_ t: Double) { backend.seek(videoId: videoId, time: t) }
}

@objc public final class SceneScriptParticlesHandle: NSObject, SceneScriptParticlesHandleExport {
    private let systemId: String
    private let backend: SceneScriptParticlesBackend
    public init(systemId: String, backend: SceneScriptParticlesBackend) {
        self.systemId = systemId
        self.backend = backend
    }
    public func setEmitterRate(_ rate: Double) {
        backend.setEmitterRate(systemId: systemId, rate: Float(rate))
    }
    public func setEmitterPosition(_ x: Double, _ y: Double) {
        backend.setEmitterPosition(systemId: systemId, x: Float(x), y: Float(y))
    }
}

// MARK: - Top-level API オブジェクト

/// `SceneScriptRuntime.attachAPI(...)` で context へインストールされる API バインディング。
public final class SceneScriptAPI {
    public let layerBackend: SceneScriptLayerBackend
    public let soundBackend: SceneScriptSoundBackend
    public let videoBackend: SceneScriptVideoBackend
    public let particlesBackend: SceneScriptParticlesBackend
    public let logSink: SceneScriptLogSink
    public let engineAPI: SceneScriptEngineAPI

    public init(layerBackend: SceneScriptLayerBackend,
                soundBackend: SceneScriptSoundBackend,
                videoBackend: SceneScriptVideoBackend,
                particlesBackend: SceneScriptParticlesBackend,
                logSink: SceneScriptLogSink,
                randomProvider: @escaping () -> Double = { drand48() }) {
        self.layerBackend = layerBackend
        self.soundBackend = soundBackend
        self.videoBackend = videoBackend
        self.particlesBackend = particlesBackend
        self.logSink = logSink
        self.engineAPI = SceneScriptEngineAPI(layerBackend: layerBackend,
                                              logSink: logSink,
                                              randomProvider: randomProvider)
    }

    /// 全 backend を 1 つの NoopSceneScriptBackends で揃える簡易ファクトリ。
    public static func noop() -> SceneScriptAPI {
        let n = NoopSceneScriptBackends()
        return SceneScriptAPI(layerBackend: n,
                              soundBackend: n,
                              videoBackend: n,
                              particlesBackend: n,
                              logSink: n)
    }

    /// JSContext へグローバルとして API を流し込む。
    public func install(into context: JSContext) {
        context.setObject(engineAPI, forKeyedSubscript: "engine" as NSString)

        // layer / sound / video / particles はファクトリ関数として公開する。
        // JS: var l = layer("foo"); l.setOpacity(0.5);
        let layerBackend = self.layerBackend
        let layerFactory: @convention(block) (String) -> SceneScriptLayerHandle = { id in
            SceneScriptLayerHandle(layerId: id, backend: layerBackend)
        }
        context.setObject(layerFactory, forKeyedSubscript: "layer" as NSString)

        let soundBackend = self.soundBackend
        let soundFactory: @convention(block) (String) -> SceneScriptSoundHandle = { id in
            SceneScriptSoundHandle(soundId: id, backend: soundBackend)
        }
        context.setObject(soundFactory, forKeyedSubscript: "sound" as NSString)

        let videoBackend = self.videoBackend
        let videoFactory: @convention(block) (String) -> SceneScriptVideoHandle = { id in
            SceneScriptVideoHandle(videoId: id, backend: videoBackend)
        }
        context.setObject(videoFactory, forKeyedSubscript: "video" as NSString)

        let particlesBackend = self.particlesBackend
        let particlesFactory: @convention(block) (String) -> SceneScriptParticlesHandle = { id in
            SceneScriptParticlesHandle(systemId: id, backend: particlesBackend)
        }
        context.setObject(particlesFactory, forKeyedSubscript: "particles" as NSString)
    }
}
