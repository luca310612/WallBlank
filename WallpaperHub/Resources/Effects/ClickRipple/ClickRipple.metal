// ClickRipple.metal
// クリック波紋エフェクト（クリック位置から広がる輪）。
// Why: マウス入力起点の演出を独立ファイルに分離。
#include "../Common/Common.metal.h"

float3 clickRipple(float2 uv, float2 clickPos, float clickTime, float3 baseColor) {
    float dist = distance(uv, clickPos);

    // 波紋の速度と減衰
    float rippleSpeed = 0.5;
    float rippleWidth = 0.05;
    float maxRadius = 1.5;

    float rippleRadius = clickTime * rippleSpeed;

    // 波紋が最大半径を超えたら消える
    if (rippleRadius > maxRadius) {
        return baseColor;
    }

    // 波紋の計算
    float ripple = sin((dist - rippleRadius) * 30.0) * 0.5 + 0.5;
    float ringMask = smoothstep(rippleRadius - rippleWidth, rippleRadius, dist) *
                     smoothstep(rippleRadius + rippleWidth, rippleRadius, dist);

    // 時間に応じて減衰
    float fadeOut = 1.0 - (rippleRadius / maxRadius);
    fadeOut = fadeOut * fadeOut; // より自然な減衰

    // 波紋の色（明るい青/シアン）
    float3 rippleColor = float3(0.3, 0.7, 1.0);

    // 波紋をベースカラーに加算
    float3 result = baseColor + rippleColor * ringMask * ripple * fadeOut * 0.8;

    // クリック位置に小さな発光
    float centerGlow = exp(-dist * dist * 50.0) * fadeOut;
    result += float3(0.5, 0.8, 1.0) * centerGlow * 0.5;

    return result;
}
