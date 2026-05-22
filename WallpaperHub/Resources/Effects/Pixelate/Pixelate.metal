// Pixelate.metal
// ピクセレートエフェクト（画面をモザイク/ドット絵風に変換する UV 量子化）。
// Why: ポストエフェクトを per-effect ファイルに分離。
#include "../Common/Common.metal.h"

float2 pixelateUV(float2 uv, constant EffectUniforms &fx) {
    if (fx.pixelateEnabled == 0) {
        return uv;
    }

    float pixelSize = fx.pixelateSize;
    float2 pixelated = floor(uv / pixelSize) * pixelSize + pixelSize * 0.5;

    return pixelated;
}
