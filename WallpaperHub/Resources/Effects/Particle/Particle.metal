// Particle.metal
// パーティクル（雨/雪）エフェクト。
// Why: 「画面に粒を重ねる」系を 1 ファイルに集約。particleHash は particleEffect 専用の
// 内部ヘルパなので同居させる。
#include "../Common/Common.metal.h"

// パーティクル用ハッシュ関数
float2 particleHash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

// パーティクルエフェクト（雨・雪）- 最適化版
// GPU負荷を軽減するため、以下の最適化を適用:
// 1. 密度に応じたレイヤー数の動的調整
// 2. 近隣セル検索の最小化（距離判定で早期スキップ）
// 3. 分岐を減らした計算
float3 particleEffect(float2 uv, float time, constant EffectUniforms &fx, float3 baseColor) {
    if (fx.particleEnabled == 0) {
        return baseColor;
    }

    float3 result = baseColor;
    float density = fx.particleDensity;
    float speed = fx.particleSpeed;
    float windAngle = fx.particleWindAngle;
    float particleSize = fx.particleSize;
    float opacity = fx.particleOpacity;
    int style = fx.particleStyle;

    // グリッドベースのセル分割
    float cellSize = 1.0 / density;
    float2 cellUV = uv / cellSize;
    float2 cellID = floor(cellUV);
    float2 cellFract = fract(cellUV);

    // 密度に応じてレイヤー数を動的に調整（低密度時はレイヤーを減らす）
    int maxLayers = (density > 30.0) ? 3 : ((density > 15.0) ? 2 : 1);

    // パーティクルカラーを事前計算（分岐を削減）
    float3 particleColor = (style == 0) ? float3(0.7, 0.8, 1.0) : float3(1.0, 1.0, 1.0);

    // 近隣セル探索の最適化: セル内位置に基づいて必要な方向のみ探索
    // 例: セルの右下にいる場合、左上方向のセルは距離が遠いのでスキップ可能
    int dxStart = (cellFract.x < 0.3) ? -1 : 0;
    int dxEnd = (cellFract.x > 0.7) ? 1 : 0;
    int dyStart = (cellFract.y < 0.3) ? -1 : 0;
    int dyEnd = (cellFract.y > 0.7) ? 1 : 0;

    for (int layer = 0; layer < maxLayers; layer++) {
        float layerSpeed = speed * (1.0 + float(layer) * 0.3);
        float layerSize = particleSize * (1.0 - float(layer) * 0.2);
        float layerOpacity = opacity * (1.0 - float(layer) * 0.25);

        // 雪の場合はサイズを調整
        if (style == 1) {
            layerSize *= 1.5;
        }

        // 早期終了用の最大距離（これ以上離れていればスキップ）
        float maxDist = layerSize * 2.0;

        for (int dy = dyStart; dy <= dyEnd; dy++) {
            for (int dx = dxStart; dx <= dxEnd; dx++) {
                float2 neighborCell = cellID + float2(dx, dy);
                float2 randomOffset = particleHash(neighborCell + float2(layer * 100.0));

                // パーティクルの位置を計算
                float2 particlePos = (neighborCell + randomOffset) * cellSize;

                // 時間による落下アニメーション
                float fallOffset = fract(time * layerSpeed * 0.5 + randomOffset.y);
                particlePos.y = fract(particlePos.y + fallOffset);

                // 風の影響
                particlePos.x = fract(particlePos.x + windAngle * fallOffset);

                // パーティクルとの距離
                float2 diff = uv - particlePos;

                // 距離の早期チェック（大まかな距離で明らかに遠いものをスキップ）
                float roughDist = abs(diff.x) + abs(diff.y);
                if (roughDist > maxDist * 2.0) {
                    continue;
                }

                float dist;
                if (style == 0) {
                    // 雨: 縦長の楕円形
                    float2 stretch = float2(1.0, 5.0 + randomOffset.x * 3.0);
                    dist = length(diff * stretch);
                } else {
                    // 雪: 円形でソフトエッジ
                    dist = length(diff);
                }

                // 距離が遠すぎる場合はスキップ
                if (dist > layerSize) {
                    continue;
                }

                // パーティクルの描画（ソフトエッジ）
                float particleAlpha = smoothstep(layerSize, layerSize * 0.2, dist);
                particleAlpha *= layerOpacity;

                // 雪の場合は輝きを追加
                if (style == 1) {
                    float sparkle = sin(time * 10.0 + randomOffset.x * 100.0) * 0.5 + 0.5;
                    particleAlpha *= 0.7 + sparkle * 0.3;
                }

                result = mix(result, particleColor, particleAlpha);
            }
        }
    }

    return result;
}
