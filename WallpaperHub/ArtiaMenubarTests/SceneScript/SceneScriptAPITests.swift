import Foundation
import JavaScriptCore
import XCTest

@testable import WallBlank

// MARK: - Mock backends

private final class MockLayerBackend: SceneScriptLayerBackend {
    struct OpacityCall: Equatable { let id: String; let value: Float }
    struct PositionCall: Equatable { let id: String; let x: Float; let y: Float }
    struct PropertyCall: Equatable { let id: String; let key: String; let value: String }

    var opacityCalls: [OpacityCall] = []
    var colorCalls: [(String, Float, Float, Float)] = []
    var scaleCalls: [(String, Float)] = []
    var positionCalls: [PositionCall] = []
    var rotationCalls: [(String, Float)] = []
    var propertyCalls: [PropertyCall] = []

    func setLayerOpacity(layerId: String, opacity: Float) {
        opacityCalls.append(OpacityCall(id: layerId, value: opacity))
    }
    func setLayerColor(layerId: String, r: Float, g: Float, b: Float) {
        colorCalls.append((layerId, r, g, b))
    }
    func setLayerScale(layerId: String, scale: Float) {
        scaleCalls.append((layerId, scale))
    }
    func setLayerPosition(layerId: String, x: Float, y: Float) {
        positionCalls.append(PositionCall(id: layerId, x: x, y: y))
    }
    func setLayerRotation(layerId: String, degrees: Float) {
        rotationCalls.append((layerId, degrees))
    }
    func setLayerProperty(layerId: String, key: String, value: Any) {
        propertyCalls.append(PropertyCall(id: layerId, key: key, value: String(describing: value)))
    }
}

private final class MockSoundBackend: SceneScriptSoundBackend {
    var trace: [String] = []
    func play(soundId: String) { trace.append("play:\(soundId)") }
    func pause(soundId: String) { trace.append("pause:\(soundId)") }
    func setVolume(soundId: String, volume: Float) { trace.append("vol:\(soundId)=\(volume)") }
}

private final class MockVideoBackend: SceneScriptVideoBackend {
    var trace: [String] = []
    func play(videoId: String) { trace.append("play:\(videoId)") }
    func pause(videoId: String) { trace.append("pause:\(videoId)") }
    func seek(videoId: String, time: Double) { trace.append("seek:\(videoId)=\(time)") }
}

private final class MockParticlesBackend: SceneScriptParticlesBackend {
    var trace: [String] = []
    func setEmitterRate(systemId: String, rate: Float) { trace.append("rate:\(systemId)=\(rate)") }
    func setEmitterPosition(systemId: String, x: Float, y: Float) {
        trace.append("pos:\(systemId)=\(x),\(y)")
    }
}

private final class MockLogSink: SceneScriptLogSink {
    var messages: [String] = []
    func receive(message: String) { messages.append(message) }
}

// MARK: - Tests

final class SceneScriptAPITests: XCTestCase {

    private func makeRuntimeAndAPI(randomProvider: @escaping () -> Double = { 0.5 }) ->
        (SceneScriptRuntime, SceneScriptAPI,
         MockLayerBackend, MockSoundBackend, MockVideoBackend, MockParticlesBackend, MockLogSink) {
        let layer = MockLayerBackend()
        let sound = MockSoundBackend()
        let video = MockVideoBackend()
        let particles = MockParticlesBackend()
        let log = MockLogSink()
        let api = SceneScriptAPI(layerBackend: layer,
                                 soundBackend: sound,
                                 videoBackend: video,
                                 particlesBackend: particles,
                                 logSink: log,
                                 randomProvider: randomProvider)
        let runtime = SceneScriptRuntime()
        runtime.attachAPI(api)
        return (runtime, api, layer, sound, video, particles, log)
    }

    func test_engineLog_routedToSwiftLogSink() {
        let (runtime, _, _, _, _, _, log) = makeRuntimeAndAPI()
        runtime.evaluate("engine.log('hello world')")
        XCTAssertEqual(log.messages, ["hello world"])
    }

    func test_engineRandom_isStubbed() {
        let (runtime, _, _, _, _, _, _) = makeRuntimeAndAPI(randomProvider: { 0.42 })
        let v = runtime.evaluate("engine.random()")?.toDouble() ?? 0
        XCTAssertEqual(v, 0.42, accuracy: 1e-6)
    }

    func test_engineTime_isMonotonicallyNonNegative() {
        let (runtime, _, _, _, _, _, _) = makeRuntimeAndAPI()
        let t = runtime.evaluate("engine.time()")?.toDouble() ?? -1
        XCTAssertGreaterThanOrEqual(t, 0)
    }

    func test_layerSetOpacity_callsBackend() {
        let (runtime, _, layer, _, _, _, _) = makeRuntimeAndAPI()
        runtime.evaluate("layer('foo').setOpacity(0.25)")
        XCTAssertEqual(layer.opacityCalls,
                       [MockLayerBackend.OpacityCall(id: "foo", value: 0.25)])
    }

    func test_layerSetColorAndScale_callsBackend() {
        let (runtime, _, layer, _, _, _, _) = makeRuntimeAndAPI()
        runtime.evaluate("var l = layer('a'); l.setColor(0.1, 0.2, 0.3); l.setScale(2);")
        XCTAssertEqual(layer.colorCalls.count, 1)
        XCTAssertEqual(layer.colorCalls[0].0, "a")
        XCTAssertEqual(layer.colorCalls[0].1, 0.1, accuracy: 1e-6)
        XCTAssertEqual(layer.scaleCalls.count, 1)
        XCTAssertEqual(layer.scaleCalls[0].0, "a")
        XCTAssertEqual(layer.scaleCalls[0].1, 2.0, accuracy: 1e-6)
    }

    func test_layerSetPositionAndRotation_callsBackend() {
        let (runtime, _, layer, _, _, _, _) = makeRuntimeAndAPI()
        runtime.evaluate("var l = layer('b'); l.setPosition(5, 7); l.setRotation(45);")
        XCTAssertEqual(layer.positionCalls,
                       [MockLayerBackend.PositionCall(id: "b", x: 5, y: 7)])
        XCTAssertEqual(layer.rotationCalls.count, 1)
        XCTAssertEqual(layer.rotationCalls[0].1, 45.0, accuracy: 1e-6)
    }

    func test_engineSetLayerProperty_callsBackend() {
        let (runtime, _, layer, _, _, _, _) = makeRuntimeAndAPI()
        runtime.evaluate("engine.setLayerProperty('layer1', 'customKey', 99)")
        XCTAssertEqual(layer.propertyCalls.count, 1)
        XCTAssertEqual(layer.propertyCalls[0].id, "layer1")
        XCTAssertEqual(layer.propertyCalls[0].key, "customKey")
    }

    func test_soundHandle_routesToBackend() {
        let (runtime, _, _, sound, _, _, _) = makeRuntimeAndAPI()
        runtime.evaluate("var s = sound('bgm'); s.play(); s.volume(0.5); s.pause();")
        XCTAssertEqual(sound.trace, ["play:bgm", "vol:bgm=0.5", "pause:bgm"])
    }

    func test_videoHandle_routesToBackend() {
        let (runtime, _, _, _, video, _, _) = makeRuntimeAndAPI()
        runtime.evaluate("var v = video('clip'); v.play(); v.seek(2.5); v.pause();")
        XCTAssertEqual(video.trace, ["play:clip", "seek:clip=2.5", "pause:clip"])
    }

    func test_particlesHandle_routesToBackend() {
        let (runtime, _, _, _, _, particles, _) = makeRuntimeAndAPI()
        runtime.evaluate("var p = particles('fire'); p.setEmitterRate(120); p.setEmitterPosition(3, 4);")
        XCTAssertEqual(particles.trace, ["rate:fire=120.0", "pos:fire=3.0,4.0"])
    }

    func test_noopBackends_areReturnedFromHelper() {
        // smoke: noop() で組み上げたランタイムから JS を呼んでもクラッシュしない
        let runtime = SceneScriptRuntime()
        runtime.attachAPI(SceneScriptAPI.noop())
        runtime.evaluate("layer('z').setOpacity(0.1); sound('s').play(); video('v').seek(1); particles('p').setEmitterRate(0);")
        XCTAssertNil(runtime.lastException)
    }
}
