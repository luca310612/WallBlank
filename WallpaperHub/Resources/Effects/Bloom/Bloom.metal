#include "../Common/Common.metal.h"

float3 bloomEffect(texture2d<float> tex, sampler s, float2 uv, float2 resolution,
                   constant EffectUniforms &fx, float3 baseColor) {
    if (fx.bloomEnabled == 0) {
        return baseColor;
    }

    float intensity = fx.bloomIntensity;
    float threshold = fx.bloomThreshold;

    float brightness = dot(baseColor, float3(0.2126, 0.7152, 0.0722));
    float bloomMask = smoothstep(threshold, threshold + 0.2, brightness);

    float2 texelSize = 1.0 / resolution;
    float3 bloomColor = float3(0.0);
    float totalWeight = 0.0;

    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            float2 offset = float2(float(x), float(y)) * texelSize * 3.0;
            float3 sampleColor = tex.sample(s, uv + offset).rgb;
            float sampleBrightness = dot(sampleColor, float3(0.2126, 0.7152, 0.0722));
            float weight = max(0.0, sampleBrightness - threshold);
            bloomColor += sampleColor * weight;
            totalWeight += weight;
        }
    }

    if (totalWeight > 0.0) {
        bloomColor /= totalWeight;
    }

    return baseColor + bloomColor * bloomMask * intensity;
}
