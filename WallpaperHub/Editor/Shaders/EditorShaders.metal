#include <metal_stdlib>
using namespace metal;

// MARK: - 頂点出力

struct EditorVertexOut {
    float4 position [[position]];
    float2 uv;
};

// MARK: - レイヤー合成用 Uniforms

struct EditorLayerUniforms {
    float opacity;
    int blendMode;
    float _pad0;
    float _pad1;

    float offsetX;
    float offsetY;
    float scaleX;
    float scaleY;
    float rotation;
    int flipH;
    int flipV;
    float _pad2;

    float brightness;
    float contrast;
    float saturation;
    float temperature;
    float sharpness;
    float gamma;
    float exposure;
    int filterType;

    float canvasWidth;
    float canvasHeight;
    float layerWidth;
    float layerHeight;
};

// MARK: - 頂点シェーダー

vertex EditorVertexOut editorVertexShader(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1),  // 左下
        float2( 1, -1),  // 右下
        float2(-1,  1),  // 左上
        float2( 1,  1)   // 右上
    };

    float2 uvs[4] = {
        float2(0, 1),    // 左下（Y反転）
        float2(1, 1),    // 右下
        float2(0, 0),    // 左上
        float2(1, 0)     // 右上
    };

    EditorVertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.uv = uvs[vertexID];
    return out;
}

// MARK: - 画像調整関数

float4 applyAdjustments(float4 color, constant EditorLayerUniforms &uniforms) {
    float3 rgb = color.rgb;

    if (abs(uniforms.exposure) > 0.001) {
        rgb *= pow(2.0, uniforms.exposure);
    }

    if (abs(uniforms.brightness) > 0.001) {
        rgb += uniforms.brightness;
    }

    if (abs(uniforms.contrast - 1.0) > 0.001) {
        rgb = (rgb - 0.5) * uniforms.contrast + 0.5;
    }

    if (abs(uniforms.saturation - 1.0) > 0.001) {
        float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luminance), rgb, uniforms.saturation);
    }

    if (abs(uniforms.temperature) > 0.001) {
        float temp = uniforms.temperature;
        rgb.r += temp * 0.1;
        rgb.b -= temp * 0.1;
        rgb.g += temp * 0.02;
    }

    if (abs(uniforms.gamma - 1.0) > 0.001) {
        rgb = pow(max(rgb, 0.0), float3(1.0 / uniforms.gamma));
    }

    rgb = clamp(rgb, 0.0, 1.0);

    return float4(rgb, color.a);
}

// MARK: - ブレンドモード関数

float3 blendColors(float3 base, float3 blend, int mode) {
    switch (mode) {
        case 0: // 通常 (Normal)
            return blend;

        case 1: // 乗算 (Multiply)
            return base * blend;

        case 2: // スクリーン (Screen)
            return 1.0 - (1.0 - base) * (1.0 - blend);

        case 3: { // オーバーレイ (Overlay)
            float3 result;
            for (int i = 0; i < 3; i++) {
                if (base[i] < 0.5) {
                    result[i] = 2.0 * base[i] * blend[i];
                } else {
                    result[i] = 1.0 - 2.0 * (1.0 - base[i]) * (1.0 - blend[i]);
                }
            }
            return result;
        }

        case 4: { // ソフトライト (Soft Light)
            float3 result;
            for (int i = 0; i < 3; i++) {
                if (blend[i] < 0.5) {
                    result[i] = 2.0 * base[i] * blend[i] + base[i] * base[i] * (1.0 - 2.0 * blend[i]);
                } else {
                    result[i] = 2.0 * base[i] * (1.0 - blend[i]) + sqrt(base[i]) * (2.0 * blend[i] - 1.0);
                }
            }
            return result;
        }

        case 5: { // ハードライト (Hard Light)
            float3 result;
            for (int i = 0; i < 3; i++) {
                if (blend[i] < 0.5) {
                    result[i] = 2.0 * base[i] * blend[i];
                } else {
                    result[i] = 1.0 - 2.0 * (1.0 - base[i]) * (1.0 - blend[i]);
                }
            }
            return result;
        }

        case 6: // 加算 (Add)
            return min(base + blend, 1.0);

        case 7: // 減算 (Subtract)
            return max(base - blend, 0.0);

        default:
            return blend;
    }
}

// MARK: - UV変形関数

float2 transformUV(float2 uv, constant EditorLayerUniforms &uniforms) {
    float canvasAspect = uniforms.canvasWidth / max(uniforms.canvasHeight, 1.0);
    float layerAspect = uniforms.layerWidth / max(uniforms.layerHeight, 1.0);

    float2 centered = uv - 0.5;

    centered.x -= uniforms.offsetX / uniforms.canvasWidth;
    centered.y -= uniforms.offsetY / uniforms.canvasHeight;

    if (abs(uniforms.rotation) > 0.001) {
        float cosR = cos(uniforms.rotation);
        float sinR = sin(uniforms.rotation);
        float2 rotated;
        rotated.x = centered.x * cosR + centered.y * sinR;
        rotated.y = -centered.x * sinR + centered.y * cosR;
        centered = rotated;
    }

    centered.x /= max(uniforms.scaleX, 0.001);
    centered.y /= max(uniforms.scaleY, 0.001);

    if (uniforms.layerWidth > 0 && uniforms.layerHeight > 0) {
        float fitScale;
        if (canvasAspect > layerAspect) {
            fitScale = uniforms.canvasHeight / uniforms.layerHeight;
        } else {
            fitScale = uniforms.canvasWidth / uniforms.layerWidth;
        }
        float scaledLayerW = uniforms.layerWidth * fitScale;
        float scaledLayerH = uniforms.layerHeight * fitScale;
        centered.x *= uniforms.canvasWidth / scaledLayerW;
        centered.y *= uniforms.canvasHeight / scaledLayerH;
    }

    if (uniforms.flipH != 0) { centered.x = -centered.x; }
    if (uniforms.flipV != 0) { centered.y = -centered.y; }

    return centered + 0.5;
}

// MARK: - シャープネス（3x3ラプラシアンカーネル）

float4 applySharpen(texture2d<float> tex, float2 uv, float sharpness) {
    if (sharpness < 0.001) {
        return tex.sample(sampler(mag_filter::linear, min_filter::linear), uv);
    }

    float2 texelSize = 1.0 / float2(tex.get_width(), tex.get_height());
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    float4 center = tex.sample(s, uv);
    float4 top = tex.sample(s, uv + float2(0, -texelSize.y));
    float4 bottom = tex.sample(s, uv + float2(0, texelSize.y));
    float4 left = tex.sample(s, uv + float2(-texelSize.x, 0));
    float4 right = tex.sample(s, uv + float2(texelSize.x, 0));

    float4 laplacian = 4.0 * center - top - bottom - left - right;
    float4 sharpened = center + laplacian * sharpness;
    sharpened = clamp(sharpened, 0.0, 1.0);
    sharpened.a = center.a;

    return sharpened;
}

// MARK: - レイヤー合成フラグメントシェーダー

fragment float4 editorCompositeFragment(
    EditorVertexOut in [[stage_in]],
    texture2d<float> canvasTexture [[texture(0)]],   // 現在のキャンバス（下のレイヤーまでの合成結果）
    texture2d<float> layerTexture [[texture(1)]],    // 合成するレイヤー
    constant EditorLayerUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float4 baseColor = canvasTexture.sample(s, in.uv);

    float2 layerUV = transformUV(in.uv, uniforms);

    if (layerUV.x < 0.0 || layerUV.x > 1.0 || layerUV.y < 0.0 || layerUV.y > 1.0) {
        return baseColor;
    }

    float4 layerColor;
    if (uniforms.sharpness > 0.001) {
        layerColor = applySharpen(layerTexture, layerUV, uniforms.sharpness);
    } else {
        layerColor = layerTexture.sample(s, layerUV);
    }

    layerColor = applyAdjustments(layerColor, uniforms);

    float3 blended = blendColors(baseColor.rgb, layerColor.rgb, uniforms.blendMode);

    float finalAlpha = layerColor.a * uniforms.opacity;
    float3 result = mix(baseColor.rgb, blended, finalAlpha);

    float resultAlpha = finalAlpha + baseColor.a * (1.0 - finalAlpha);

    return float4(result, resultAlpha);
}

// MARK: - キャンバスクリアシェーダー

fragment float4 editorClearFragment(
    EditorVertexOut in [[stage_in]]
) {
    return float4(0.0, 0.0, 0.0, 0.0);
}

// MARK: - プレビュー表示シェーダー

fragment float4 editorPreviewFragment(
    EditorVertexOut in [[stage_in]],
    texture2d<float> compositeTexture [[texture(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 color = compositeTexture.sample(s, in.uv);

    if (color.a < 1.0) {
        float2 pixelPos = in.uv * float2(compositeTexture.get_width(), compositeTexture.get_height());
        float checkerSize = 8.0;
        int cx = int(floor(pixelPos.x / checkerSize));
        int cy = int(floor(pixelPos.y / checkerSize));
        float checker = ((cx + cy) % 2 == 0) ? 0.85 : 0.75;
        float3 checkerColor = float3(checker);

        color.rgb = mix(checkerColor, color.rgb, color.a);
        color.a = 1.0;
    }

    return color;
}
