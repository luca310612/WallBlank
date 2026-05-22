#include "../Common/Common.metal.h"

float2 particleHash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

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

    float cellSize = 1.0 / density;
    float2 cellUV = uv / cellSize;
    float2 cellID = floor(cellUV);
    float2 cellFract = fract(cellUV);

    int maxLayers = (density > 30.0) ? 3 : ((density > 15.0) ? 2 : 1);

    float3 particleColor = (style == 0) ? float3(0.7, 0.8, 1.0) : float3(1.0, 1.0, 1.0);

    int dxStart = (cellFract.x < 0.3) ? -1 : 0;
    int dxEnd = (cellFract.x > 0.7) ? 1 : 0;
    int dyStart = (cellFract.y < 0.3) ? -1 : 0;
    int dyEnd = (cellFract.y > 0.7) ? 1 : 0;

    for (int layer = 0; layer < maxLayers; layer++) {
        float layerSpeed = speed * (1.0 + float(layer) * 0.3);
        float layerSize = particleSize * (1.0 - float(layer) * 0.2);
        float layerOpacity = opacity * (1.0 - float(layer) * 0.25);

        if (style == 1) {
            layerSize *= 1.5;
        }

        float maxDist = layerSize * 2.0;

        for (int dy = dyStart; dy <= dyEnd; dy++) {
            for (int dx = dxStart; dx <= dxEnd; dx++) {
                float2 neighborCell = cellID + float2(dx, dy);
                float2 randomOffset = particleHash(neighborCell + float2(layer * 100.0));

                float2 particlePos = (neighborCell + randomOffset) * cellSize;

                float fallOffset = fract(time * layerSpeed * 0.5 + randomOffset.y);
                particlePos.y = fract(particlePos.y + fallOffset);

                particlePos.x = fract(particlePos.x + windAngle * fallOffset);

                float2 diff = uv - particlePos;

                float roughDist = abs(diff.x) + abs(diff.y);
                if (roughDist > maxDist * 2.0) {
                    continue;
                }

                float dist;
                if (style == 0) {
                    float2 stretch = float2(1.0, 5.0 + randomOffset.x * 3.0);
                    dist = length(diff * stretch);
                } else {
                    dist = length(diff);
                }

                if (dist > layerSize) {
                    continue;
                }

                float particleAlpha = smoothstep(layerSize, layerSize * 0.2, dist);
                particleAlpha *= layerOpacity;

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
