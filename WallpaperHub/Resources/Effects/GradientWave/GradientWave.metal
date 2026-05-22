// GradientWave.metal
// グラデーション波の背景シェーダー（ShaderType==1）。
// Why: 背景プロシージャル群を per-effect ファイルに分離し、追加・差し替えを
// シェーダ単位でできるようにする。
#include "../Common/Common.metal.h"

float3 gradientWave(float2 uv, float time) {
    float wave = sin(uv.x * 10.0 + time * 2.0) * 0.1;
    wave += sin(uv.y * 8.0 + time * 1.5) * 0.1;

    float3 color1 = float3(0.1, 0.2, 0.4); // 深い青
    float3 color2 = float3(0.4, 0.1, 0.6); // 紫
    float3 color3 = float3(0.1, 0.4, 0.5); // ティール

    float t = uv.x + uv.y + wave;
    t = fract(t * 0.5 + time * 0.1);

    float3 color;
    if (t < 0.33) {
        color = mix(color1, color2, t * 3.0);
    } else if (t < 0.66) {
        color = mix(color2, color3, (t - 0.33) * 3.0);
    } else {
        color = mix(color3, color1, (t - 0.66) * 3.0);
    }

    return color;
}
