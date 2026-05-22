#include "../Common/Common.metal.h"

float2 waterRippleDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                             constant EffectUniforms &fx, int hasMask) {
    if (fx.waterRippleEnabled == 0) {
        return uv;
    }

    float intensity = fx.waterRippleIntensity;
    float speed = fx.waterRippleSpeed;
    float scale = fx.waterRippleScale;

    float2 center1 = float2(0.3, 0.7);
    float2 center2 = float2(0.7, 0.4);
    float2 center3 = float2(0.5, 0.6);

    float dist1 = distance(uv, center1);
    float dist2 = distance(uv, center2);
    float dist3 = distance(uv, center3);

    float wave1 = sin(dist1 * scale * 2.0 - time * speed * 1.0) * 0.5;
    float wave2 = sin(dist2 * scale * 2.5 - time * speed * 0.8 + 1.5) * 0.35;
    float wave3 = sin(dist3 * scale * 1.8 - time * speed * 1.2 + 3.0) * 0.25;

    float noiseWave = noise(uv * scale * 3.0 + float2(time * speed * 0.3, 0.0)) * 0.15;

    float2 grad1 = normalize(uv - center1 + 0.001) * wave1;
    float2 grad2 = normalize(uv - center2 + 0.001) * wave2;
    float2 grad3 = normalize(uv - center3 + 0.001) * wave3;

    float2 displacement = (grad1 + grad2 + grad3) * intensity;

    float edgeFade = smoothstep(0.0, 0.1, uv.x) * smoothstep(1.0, 0.9, uv.x)
                   * smoothstep(0.0, 0.1, uv.y) * smoothstep(1.0, 0.9, uv.y);

    float maskValue = 1.0;
    if (fx.waterRippleUseMask != 0 && hasMask != 0) {
        maskValue = maskTex.sample(s, uv).r;
    }

    return uv + displacement * edgeFade * maskValue;
}

float3 waterRippleReflection(float2 uv, float time, constant EffectUniforms &fx, float3 baseColor) {
    if (fx.waterRippleEnabled == 0 || fx.waterRippleReflection <= 0.0) {
        return baseColor;
    }

    float speed = fx.waterRippleSpeed;
    float scale = fx.waterRippleScale;
    float reflectionStrength = fx.waterRippleReflection;

    float2 p = uv * scale;
    float caustic1 = sin(p.x * 3.0 + time * speed * 0.5) * sin(p.y * 3.0 + time * speed * 0.7);
    float caustic2 = sin(p.x * 5.0 - time * speed * 0.3 + 1.0) * sin(p.y * 4.0 + time * speed * 0.4 + 2.0);
    float caustics = (caustic1 + caustic2) * 0.5;
    caustics = pow(max(caustics, 0.0), 2.0);

    float3 reflectionColor = float3(0.8, 0.9, 1.0) * caustics * reflectionStrength;

    return baseColor + reflectionColor;
}
