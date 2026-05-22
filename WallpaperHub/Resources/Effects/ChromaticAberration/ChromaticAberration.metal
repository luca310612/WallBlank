// ChromaticAberration.metal
// 色収差エフェクト（RGB各チャンネルを異なる方向にオフセットして色ずれを表現）。
// Why: ポストエフェクトを per-effect ファイルに分離。
#include "../Common/Common.metal.h"

float3 chromaticAberration(texture2d<float> tex, sampler s, float2 uv,
                           constant EffectUniforms &fx, float3 baseColor) {
    if (fx.chromaticEnabled == 0) {
        return baseColor;
    }

    float intensity = fx.chromaticIntensity;
    float angle = fx.chromaticAngle;

    float2 dir = float2(cos(angle), sin(angle)) * intensity;

    float r = tex.sample(s, uv + dir).r;
    float g = tex.sample(s, uv).g;
    float b = tex.sample(s, uv - dir).b;

    return float3(r, g, b);
}
