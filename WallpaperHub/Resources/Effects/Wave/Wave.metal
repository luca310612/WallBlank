// Wave.metal
// ウェーブ歪みエフェクト（fbm ベースの粒感ある面の揺れ）。
// Why: 歪み系を per-effect ファイルに分離して個別差し替え可能にする。
//
// 設計:
//  - 受け取る uv は「画像 UV(maskUV)」基準。MaskEditor の fit 表示と同じ座標系。
//  - 「細かい粒・凹凸」のある面で揺れるイメージ。サイン波合成だと縞模様になり
//    粒感が出ないため、fbm ノイズで X/Y それぞれ独立にずらす。
//  - マスク使用時: マスク値そのものが「揺れる量の重み」になる。
//    マスクで塗った場所だけが揺れ、塗っていない場所は完全静止。
//  - マスク非使用時: 上部ほど強く揺らす旧来挙動を維持。
//  - frequency はノイズスケール、amplitude はピクセル偏移、speed は時間進行。
#include "../Common/Common.metal.h"

float2 waveDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                      constant EffectUniforms &fx, int hasMask) {
    if (fx.waveEnabled == 0) {
        return uv;
    }

    float amplitude = fx.waveAmplitude;
    float frequency = fx.waveFrequency;
    float speed = fx.waveSpeed;

    // ノイズの座標。frequency が高いほど細かい粒になる。
    float2 p = uv * frequency;
    float t = time * speed;

    // 2 つの fbm をサンプル位置を変えて取り、X/Y にそれぞれ充てる。
    // これで「点ごとに少しずつ違う方向に動く粒の集合」になる。
    // fbm は 0..1 を返すので -0.5..0.5 にシフト（ゼロ中心の歪み）。
    float nx = fbm(p + float2(t * 0.6, t * 0.3), 4) - 0.5;
    float ny = fbm(p + float2(-t * 0.4, t * 0.5) + float2(17.3, 31.7), 4) - 0.5;

    // 細かい高周波ノイズを足してさらに粒感を強める。
    float nx2 = fbm(p * 2.7 + float2(t * 0.9, 0.0), 3) - 0.5;
    float ny2 = fbm(p * 2.7 + float2(0.0, t * 0.85) + float2(91.2, 4.7), 3) - 0.5;

    float2 noise = float2(nx + nx2 * 0.5, ny + ny2 * 0.5);

    float weight;
    if (fx.waveUseMask != 0 && hasMask != 0) {
        weight = maskTex.sample(s, uv).r;
    } else {
        weight = pow(1.0 - uv.y, 0.5);
    }

    return uv + noise * amplitude * weight;
}
