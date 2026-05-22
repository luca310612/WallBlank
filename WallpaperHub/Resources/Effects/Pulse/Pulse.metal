#include "../Common/Common.metal.h"

float3 pulseEffect(texture2d<float> tex, sampler s, float2 uv, float2 resolution,
                   constant EffectUniforms &fx, float3 baseColor,
                   float bassAmplitude, float strength) {
    if (bassAmplitude <= 0.0 || strength <= 0.0) {
        return baseColor;
    }
    float2 centered = uv - float2(0.5, 0.5);
    float scale = 1.0 + bassAmplitude * strength;
    float2 scaledUV = centered / scale + float2(0.5, 0.5);

    scaledUV = clamp(scaledUV, float2(0.0), float2(1.0));
    float3 pulsed = tex.sample(s, scaledUV).rgb;
    return mix(baseColor, pulsed, 0.5 + 0.5 * bassAmplitude);
}
