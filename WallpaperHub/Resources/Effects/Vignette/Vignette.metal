// Vignette.metal
// ビネットエフェクト（画面端を暗くして映画風の雰囲気を演出）。
// Why: ポストエフェクトを per-effect ファイルに分離。
#include "../Common/Common.metal.h"

float3 vignetteEffect(float2 uv, constant EffectUniforms &fx, float3 baseColor) {
    if (fx.vignetteEnabled == 0) {
        return baseColor;
    }

    float intensity = fx.vignetteIntensity;
    float radius = fx.vignetteRadius;

    // 中心からの距離を計算
    float2 center = uv - 0.5;
    float dist = length(center);

    // ビネットマスクを計算（スムーズなフォールオフ）
    float vignette = smoothstep(radius, radius - 0.3, dist);
    vignette = pow(vignette, intensity);

    return baseColor * vignette;
}
