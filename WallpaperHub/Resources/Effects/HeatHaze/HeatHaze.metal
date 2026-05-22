// HeatHaze.metal
// 陽炎エフェクト（熱波で画面全体が揺らめく効果）。
// Why: 歪み系を per-effect ファイルに分離。
#include "../Common/Common.metal.h"

float2 heatHazeDistortion(float2 uv, float time, constant EffectUniforms &fx) {
    if (fx.heatHazeEnabled == 0) {
        return uv;
    }

    float intensity = fx.heatHazeIntensity;
    float speed = fx.heatHazeSpeed;
    float scale = fx.heatHazeScale;

    // 複数周波数の正弦波で自然な揺らぎを表現
    float distX = sin(uv.y * scale + time * speed) * intensity;
    distX += sin(uv.y * scale * 1.7 + time * speed * 0.7 + 1.3) * intensity * 0.5;
    distX += sin(uv.y * scale * 0.5 + time * speed * 1.3 + 2.7) * intensity * 0.3;

    float distY = sin(uv.x * scale * 0.8 + time * speed * 0.9) * intensity * 0.5;
    distY += cos(uv.x * scale * 1.3 + time * speed * 0.6 + 1.0) * intensity * 0.3;

    // 下部ほど揺らぎを強く（地面の熱気のイメージ）
    float verticalMask = pow(1.0 - uv.y, 1.5);

    return uv + float2(distX, distY) * verticalMask;
}
