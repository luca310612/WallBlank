#include "../Common/Common.metal.h"

float3 clickRipple(float2 uv, float2 clickPos, float clickTime, float3 baseColor) {
    float dist = distance(uv, clickPos);

    float rippleSpeed = 0.5;
    float rippleWidth = 0.05;
    float maxRadius = 1.5;

    float rippleRadius = clickTime * rippleSpeed;

    if (rippleRadius > maxRadius) {
        return baseColor;
    }

    float ripple = sin((dist - rippleRadius) * 30.0) * 0.5 + 0.5;
    float ringMask = smoothstep(rippleRadius - rippleWidth, rippleRadius, dist) *
                     smoothstep(rippleRadius + rippleWidth, rippleRadius, dist);

    float fadeOut = 1.0 - (rippleRadius / maxRadius);
    fadeOut = fadeOut * fadeOut; // より自然な減衰

    float3 rippleColor = float3(0.3, 0.7, 1.0);

    float3 result = baseColor + rippleColor * ringMask * ripple * fadeOut * 0.8;

    float centerGlow = exp(-dist * dist * 50.0) * fadeOut;
    result += float3(0.5, 0.8, 1.0) * centerGlow * 0.5;

    return result;
}
