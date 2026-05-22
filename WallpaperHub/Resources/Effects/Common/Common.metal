// Common.metal
// ノイズ・FBM・アスペクト比 UV 変換の共有実装。
// Why: 複数の背景・歪み・ポストエフェクトから参照されるユーティリティを 1 ヶ所にまとめ、
// 重複定義を防ぎ将来の half/float 統一の足場とする。
#include "Common.metal.h"

// ノイズ関数（half精度で高速化）
half hash_h(half2 p) {
    return fract(sin(dot(p, half2(127.1h, 311.7h))) * 43758.5h);
}

half noise_h(half2 p) {
    half2 i = floor(p);
    half2 f = fract(p);
    half2 u = f * f * (3.0h - 2.0h * f);

    return mix(mix(hash_h(i + half2(0.0h, 0.0h)),
                   hash_h(i + half2(1.0h, 0.0h)), u.x),
               mix(hash_h(i + half2(0.0h, 1.0h)),
                   hash_h(i + half2(1.0h, 1.0h)), u.x), u.y);
}

// float版ラッパー（互換性維持）
float noise(float2 p) {
    return float(noise_h(half2(p)));
}

half fbm_h(half2 p, int octaves) {
    half value = 0.0h;
    half amplitude = 0.5h;
    half frequency = 1.0h;

    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise_h(p * frequency);
        frequency *= 2.0h;
        amplitude *= 0.5h;
    }

    return value;
}

// float版ラッパー（互換性維持）
float fbm(float2 p, int octaves) {
    return float(fbm_h(half2(p), octaves));
}

// アスペクト比を維持して画面を埋めるUV計算（aspect fill）
float2 aspectFillUV(float2 uv, float2 screenSize, float2 textureSize) {
    float screenAspect = screenSize.x / screenSize.y;
    float textureAspect = textureSize.x / textureSize.y;
    float2 scale = float2(1.0);
    if (textureAspect > screenAspect) {
        scale.x = textureAspect / screenAspect;
    } else {
        scale.y = screenAspect / textureAspect;
    }
    float2 offset = (scale - float2(1.0)) * 0.5;
    return (uv + offset) / scale;
}

// アスペクト比を維持してテクスチャ全体を収めるUV計算（aspect fit）
float2 aspectFitUV(float2 uv, float2 screenSize, float2 textureSize) {
    float screenAspect = screenSize.x / screenSize.y;
    float textureAspect = textureSize.x / textureSize.y;
    float2 scale = float2(1.0);
    if (textureAspect > screenAspect) {
        scale.y = screenAspect / textureAspect;
    } else {
        scale.x = textureAspect / screenAspect;
    }
    float2 offset = (float2(1.0) - scale) * 0.5;
    return (uv - offset) / scale;
}
