#include "../Common/Common.metal.h"

float2 heatHazeDistortion(float2 uv, float time, constant EffectUniforms &fx) {
    if (fx.heatHazeEnabled == 0) {
        return uv;
    }

    float intensity = fx.heatHazeIntensity;
    float speed = fx.heatHazeSpeed;
    float scale = fx.heatHazeScale;

    float distX = sin(uv.y * scale + time * speed) * intensity;
    distX += sin(uv.y * scale * 1.7 + time * speed * 0.7 + 1.3) * intensity * 0.5;
    distX += sin(uv.y * scale * 0.5 + time * speed * 1.3 + 2.7) * intensity * 0.3;

    float distY = sin(uv.x * scale * 0.8 + time * speed * 0.9) * intensity * 0.5;
    distY += cos(uv.x * scale * 1.3 + time * speed * 0.6 + 1.0) * intensity * 0.3;

    float verticalMask = pow(1.0 - uv.y, 1.5);

    return uv + float2(distX, distY) * verticalMask;
}
