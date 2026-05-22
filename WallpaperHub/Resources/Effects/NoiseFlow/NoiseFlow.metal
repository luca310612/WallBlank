#include "../Common/Common.metal.h"

float3 noiseFlow(float2 uv, float time, int octaves) {
    half2 p = half2(uv) * 3.0h;
    half t = half(time);

    half n1 = fbm_h(p + half2(t * 0.1h, t * 0.05h), octaves);
    half n2 = fbm_h(p + half2(n1 * 2.0h, t * 0.1h), octaves);

    half3 color1 = half3(0.0h, 0.1h, 0.2h);
    half3 color2 = half3(0.0h, 0.4h, 0.6h);
    half3 color3 = half3(0.2h, 0.6h, 0.8h);

    half3 color;

    if (octaves >= 4) {
        half n3 = fbm_h(p + half2(n2 * 2.0h, n1 * 2.0h) + t * 0.05h, octaves);
        color = mix(color1, color2, n2);
        color = mix(color, color3, n3 * 0.5h);
        half glow = pow(n3, 2.0h) * 0.5h;
        color += half3(0.1h, 0.3h, 0.5h) * glow;
    } else {
        color = mix(color1, color2, n1);
        color = mix(color, color3, n2 * 0.5h);
        half glow = pow(n2, 2.0h) * 0.5h;
        color += half3(0.1h, 0.3h, 0.5h) * glow;
    }

    return float3(color);
}
