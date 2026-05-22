#include "Common.metal.h"

half hash_h(half2 p) {
    return fract(sin(dot(p, half2(127.1h, 311.7h))) * 43758.5h);
}

half noise_h(half2 p) {
    half2 i = floor(p);
    half2 f = fract(p);
    half2 u = f * f * (3.0h - 2.0h * f);

    return mix(mix(hash_h(i + half2(0.0h, 0.0h)),
                   hash_h(i + half2(1.0h, 0.0h)), u.x),
               mix(hash_h(i + half2(0.0h, 1.0h)),
                   hash_h(i + half2(1.0h, 1.0h)), u.x), u.y);
}

float noise(float2 p) {
    return float(noise_h(half2(p)));
}

half fbm_h(half2 p, int octaves) {
    half value = 0.0h;
    half amplitude = 0.5h;
    half frequency = 1.0h;

    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise_h(p * frequency);
        frequency *= 2.0h;
        amplitude *= 0.5h;
    }

    return value;
}

float fbm(float2 p, int octaves) {
    return float(fbm_h(half2(p), octaves));
}

float2 aspectFillUV(float2 uv, float2 screenSize, float2 textureSize) {
    float screenAspect = screenSize.x / screenSize.y;
    float textureAspect = textureSize.x / textureSize.y;
    float2 scale = float2(1.0);
    if (textureAspect > screenAspect) {
        scale.x = textureAspect / screenAspect;
    } else {
        scale.y = screenAspect / textureAspect;
    }
    float2 offset = (scale - float2(1.0)) * 0.5;
    return (uv + offset) / scale;
}

float2 aspectFitUV(float2 uv, float2 screenSize, float2 textureSize) {
    float screenAspect = screenSize.x / screenSize.y;
    float textureAspect = textureSize.x / textureSize.y;
    float2 scale = float2(1.0);
    if (textureAspect > screenAspect) {
        scale.y = screenAspect / textureAspect;
    } else {
        scale.x = textureAspect / screenAspect;
    }
    float2 offset = (float2(1.0) - scale) * 0.5;
    return (uv - offset) / scale;
}
