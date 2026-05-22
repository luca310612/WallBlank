#include "../Common/Common.metal.h"

float3 vignetteEffect(float2 uv, constant EffectUniforms &fx, float3 baseColor) {
    if (fx.vignetteEnabled == 0) {
        return baseColor;
    }

    float intensity = fx.vignetteIntensity;
    float radius = fx.vignetteRadius;

    float2 center = uv - 0.5;
    float dist = length(center);

    float vignette = smoothstep(radius, radius - 0.3, dist);
    vignette = pow(vignette, intensity);

    return baseColor * vignette;
}
