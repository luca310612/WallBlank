// Blur.metal
// ぼかしエフェクト（gaussianBlur ヘルパ + マスク対応 blurEffect）。
// Why: blurEffect は内部で gaussianBlur を呼び出す。両者は密結合のため同居させる。
#include "../Common/Common.metal.h"

// ガウシアンブラー（9タップ近似）
float3 gaussianBlur(texture2d<float> tex, sampler s, float2 uv, float2 resolution, float intensity) {
    float2 texelSize = 1.0 / resolution;
    float2 offset = texelSize * intensity;

    // 9タップガウシアンカーネル
    float3 result = float3(0.0);
    float weights[9] = {0.0625, 0.125, 0.0625, 0.125, 0.25, 0.125, 0.0625, 0.125, 0.0625};
    float2 offsets[9] = {
        float2(-1, -1), float2(0, -1), float2(1, -1),
        float2(-1,  0), float2(0,  0), float2(1,  0),
        float2(-1,  1), float2(0,  1), float2(1,  1)
    };

    for (int i = 0; i < 9; i++) {
        float2 sampleUV = uv + offsets[i] * offset;
        result += tex.sample(s, sampleUV).rgb * weights[i];
    }

    return result;
}

// ぼかしエフェクト（マスク対応）
float3 blurEffect(texture2d<float> tex, texture2d<float> maskTex, sampler s,
                  float2 uv, float2 resolution, constant EffectUniforms &fx,
                  float3 baseColor, int hasMask) {
    if (fx.blurEnabled == 0) {
        return baseColor;
    }

    float intensity = fx.blurIntensity;
    float3 blurredColor = gaussianBlur(tex, s, uv, resolution, intensity);

    // マスク使用時は領域を制限
    if (fx.blurUseMask != 0 && hasMask != 0) {
        float maskValue = maskTex.sample(s, uv).r;
        return mix(baseColor, blurredColor, maskValue);
    }

    return blurredColor;
}
