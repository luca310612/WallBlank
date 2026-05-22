#include "../Common/Common.metal.h"

float2 waveDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                      constant EffectUniforms &fx, int hasMask) {
    if (fx.waveEnabled == 0) {
        return uv;
    }

    float amplitude = fx.waveAmplitude;
    float frequency = fx.waveFrequency;
    float speed = fx.waveSpeed;

    float2 p = uv * frequency;
    float t = time * speed;

    float nx = fbm(p + float2(t * 0.6, t * 0.3), 4) - 0.5;
    float ny = fbm(p + float2(-t * 0.4, t * 0.5) + float2(17.3, 31.7), 4) - 0.5;

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
