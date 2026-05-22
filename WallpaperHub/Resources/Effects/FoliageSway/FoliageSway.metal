// FoliageSway.metal
// 植物揺れエフェクト（風になびくような有機的な揺れ）。
// Why: 歪み系を per-effect ファイルに分離。
#include "../Common/Common.metal.h"

float2 foliageSwayDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                             constant EffectUniforms &fx, int hasMask) {
    if (fx.foliageSwayEnabled == 0) {
        return uv;
    }

    float intensity = fx.foliageSwayIntensity;
    float speed = fx.foliageSwaySpeed;
    float complexity = fx.foliageSwayComplexity;

    // 基本の風の動き（大きなうねり）
    float windBase = sin(time * speed * 0.7 + uv.x * 2.0) * 0.6
                   + sin(time * speed * 0.5 + 1.3) * 0.4;

    // 複雑さに応じたノイズレイヤー
    float detailSway = 0.0;
    float amp = 1.0;
    float freq = 3.0;
    int layers = int(complexity);

    for (int i = 0; i < 4; i++) {
        if (i >= layers) break;
        detailSway += noise(uv * freq + float2(time * speed * (0.3 + float(i) * 0.15), float(i) * 1.7)) * amp;
        amp *= 0.5;
        freq *= 1.8;
    }

    // 横方向と縦方向の揺れを合成
    float swayX = (windBase + detailSway * 0.5) * intensity;
    float swayY = sin(time * speed * 0.9 + uv.x * 3.0 + uv.y * 2.0) * intensity * 0.3;

    // 上部ほど揺れを強く（根元は固定、先端が大きく揺れる）
    float verticalWeight = 1.0 - uv.y;
    verticalWeight = pow(verticalWeight, 0.8);

    // マスク使用時は領域を制限
    float maskValue = 1.0;
    if (fx.foliageSwayUseMask != 0 && hasMask != 0) {
        maskValue = maskTex.sample(s, uv).r;
    }

    float2 displacement = float2(swayX, swayY) * verticalWeight * maskValue;

    return uv + displacement;
}
