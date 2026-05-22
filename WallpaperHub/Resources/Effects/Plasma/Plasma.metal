#include "../Common/Common.metal.h"

float3 plasma(float2 uv, float time) {
    float v1 = sin(uv.x * 10.0 + time);
    float v2 = sin(10.0 * (uv.x * sin(time / 2.0) + uv.y * cos(time / 3.0)) + time);
    float v3 = sin(sqrt(100.0 * ((uv.x - 0.5) * (uv.x - 0.5) + (uv.y - 0.5) * (uv.y - 0.5))) + time);
    float v = v1 + v2 + v3;

    float3 color;
    color.r = sin(v * M_PI_F);
    color.g = sin(v * M_PI_F + 2.0 * M_PI_F / 3.0);
    color.b = sin(v * M_PI_F + 4.0 * M_PI_F / 3.0);

    color = color * 0.5 + 0.5;
    return color;
}
