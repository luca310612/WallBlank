// Pulse.metal
// Phase 6A: 低域帯 (bass) の振幅で画像を放射状に拡大するオーディオリアクティブエフェクト。
// Why: Audio uniform は WGSL 側に持つが、Metal 経路ではポストエフェクト用に
//      簡易な "bass で画面が脈打つ" 表現を提供する。
#include "../Common/Common.metal.h"

// EffectUniforms に pulse 用フィールドを追加するときの想定: pulseEnabled / pulseBass / pulseStrength。
// Why: 既存 EffectUniforms との衝突回避のため、フィールドが無くても完全 no-op に倒せる構造にする。
float3 pulseEffect(texture2d<float> tex, sampler s, float2 uv, float2 resolution,
                   constant EffectUniforms &fx, float3 baseColor,
                   float bassAmplitude, float strength) {
    if (bassAmplitude <= 0.0 || strength <= 0.0) {
        return baseColor;
    }
    // 中央 (0.5, 0.5) からの方向で UV を放射状にスケール。
    // bass=1 / strength=0.05 で +5% 拡大 (要件と一致)。
    float2 centered = uv - float2(0.5, 0.5);
    float scale = 1.0 + bassAmplitude * strength;
    float2 scaledUV = centered / scale + float2(0.5, 0.5);

    // クランプ (画面外サンプル防止)。
    scaledUV = clamp(scaledUV, float2(0.0), float2(1.0));
    float3 pulsed = tex.sample(s, scaledUV).rgb;
    // 軽くベースと混ぜることで急峻な揺れを抑える。
    return mix(baseColor, pulsed, 0.5 + 0.5 * bassAmplitude);
}
