#include "../Common/Common.metal.h"

float2 pixelateUV(float2 uv, constant EffectUniforms &fx) {
    if (fx.pixelateEnabled == 0) {
        return uv;
    }

    float pixelSize = fx.pixelateSize;
    float2 pixelated = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;

    return pixelated;
}
