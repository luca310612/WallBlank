// Glitch.metal
// グリッチエフェクト（デジタルグリッチ風のブロックノイズと RGB シフト）。
// Why: ポストエフェクトを per-effect ファイルに分離。
#include "../Common/Common.metal.h"

float3 glitchEffect(texture2d<float> tex, sampler s, float2 uv, float time,
                    constant EffectUniforms &fx, float3 baseColor) {
    if (fx.glitchEnabled == 0) {
        return baseColor;
    }

    float intensity = fx.glitchIntensity;
    float speed = fx.glitchSpeed;
    float blockSize = fx.glitchBlockSize;

    // 時間ベースのランダム値（ブロック単位でグリッチ発生）
    float t = floor(time * speed);
    float blockY = floor(uv.y / blockSize);
    float noise1 = fract(sin(dot(float2(t, blockY), float2(12.9898, 78.233))) * 43758.5453);
    float noise2 = fract(sin(dot(float2(t + 1.0, blockY), float2(12.9898, 78.233))) * 43758.5453);

    // グリッチが発生するかどうか（確率はintensityに依存）
    float glitchTrigger = step(1.0 - intensity * 3.0, noise1);

    // 横方向のオフセット
    float xOffset = (noise2 - 0.5) * intensity * 2.0 * glitchTrigger;

    // スキャンライン風のノイズ
    float scanline = fract(sin(uv.y * 300.0 + time * 50.0) * 43758.5) * 0.03 * glitchTrigger;

    float2 glitchUV = uv;
    glitchUV.x += xOffset + scanline;

    // RGB分離（グリッチ時のみ）
    float rgbSplit = intensity * 0.02 * glitchTrigger;
    float r = tex.sample(s, glitchUV + float2(rgbSplit, 0.0)).r;
    float g = tex.sample(s, glitchUV).g;
    float b = tex.sample(s, glitchUV - float2(rgbSplit, 0.0)).b;

    float3 glitchColor = float3(r, g, b);

    // 元の色とミックス（グリッチが発生していない行はそのまま）
    return mix(baseColor, glitchColor, glitchTrigger);
}
