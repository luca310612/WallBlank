#include <metal_stdlib>
using namespace metal;

// MARK: - 頂点出力

struct EditorVertexOut {
    float4 position [[position]];
    float2 uv;
};

// MARK: - レイヤー合成用 Uniforms
// Swift側の EditorLayerUniforms と完全一致させる

struct EditorLayerUniforms {
    // ブレンド設定 (16 bytes)
    float opacity;
    int blendMode;
    float _pad0;
    float _pad1;

    // 変形 (32 bytes)
    float offsetX;
    float offsetY;
    float scaleX;
    float scaleY;
    float rotation;
    int flipH;
    int flipV;
    float _pad2;

    // 画像調整 (32 bytes)
    float brightness;
    float contrast;
    float saturation;
    float temperature;
    float sharpness;
    float gamma;
    float exposure;
    int filterType;

    // キャンバス情報 (16 bytes)
    float canvasWidth;
    float canvasHeight;
    float layerWidth;
    float layerHeight;
};

// MARK: - 頂点シェーダー

/// フルスクリーン四角形の頂点シェーダー
vertex EditorVertexOut editorVertexShader(uint vertexID [[vertex_id]]) {
    // フルスクリーン三角形ストリップ（2三角形 = 4頂点）
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

/// 明るさ・コントラスト・彩度・色温度・ガンマ・露出を適用
float4 applyAdjustments(float4 color, constant EditorLayerUniforms &uniforms) {
    float3 rgb = color.rgb;

    // 露出（2^exposure の乗算）
    if (abs(uniforms.exposure) > 0.001) {
        rgb *= pow(2.0, uniforms.exposure);
    }

    // 明るさ（加算）
    if (abs(uniforms.brightness) > 0.001) {
        rgb += uniforms.brightness;
    }

    // コントラスト（0.5を中心にスケーリング）
    if (abs(uniforms.contrast - 1.0) > 0.001) {
        rgb = (rgb - 0.5) * uniforms.contrast + 0.5;
    }

    // 彩度（輝度との混合）
    if (abs(uniforms.saturation - 1.0) > 0.001) {
        float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luminance), rgb, uniforms.saturation);
    }

    // 色温度（暖色↔寒色シフト）
    if (abs(uniforms.temperature) > 0.001) {
        float temp = uniforms.temperature;
        // 暖色: R↑ B↓、寒色: R↓ B↑
        rgb.r += temp * 0.1;
        rgb.b -= temp * 0.1;
        // 緑は微調整
        rgb.g += temp * 0.02;
    }

    // ガンマ補正
    if (abs(uniforms.gamma - 1.0) > 0.001) {
        rgb = pow(max(rgb, 0.0), float3(1.0 / uniforms.gamma));
    }

    // クランプ
    rgb = clamp(rgb, 0.0, 1.0);

    return float4(rgb, color.a);
}

// MARK: - ブレンドモード関数

/// 2色をブレンドモードで合成
/// base: 下のレイヤー、blend: 上のレイヤー
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

/// レイヤーのUV座標を変形（移動・スケール・回転・反転）
float2 transformUV(float2 uv, constant EditorLayerUniforms &uniforms) {
    // キャンバスとレイヤーのアスペクト比を考慮
    float canvasAspect = uniforms.canvasWidth / max(uniforms.canvasHeight, 1.0);
    float layerAspect = uniforms.layerWidth / max(uniforms.layerHeight, 1.0);

    // UV座標を中心原点に移動（0-1 → -0.5～0.5）
    float2 centered = uv - 0.5;

    // オフセット（ピクセル単位→正規化座標）
    centered.x -= uniforms.offsetX / uniforms.canvasWidth;
    centered.y -= uniforms.offsetY / uniforms.canvasHeight;

    // 回転
    if (abs(uniforms.rotation) > 0.001) {
        float cosR = cos(uniforms.rotation);
        float sinR = sin(uniforms.rotation);
        float2 rotated;
        rotated.x = centered.x * cosR + centered.y * sinR;
        rotated.y = -centered.x * sinR + centered.y * cosR;
        centered = rotated;
    }

    // スケール
    centered.x /= max(uniforms.scaleX, 0.001);
    centered.y /= max(uniforms.scaleY, 0.001);

    // アスペクト比補正（レイヤー画像をキャンバスにフィット）
    if (uniforms.layerWidth > 0 && uniforms.layerHeight > 0) {
        float fitScale;
        if (canvasAspect > layerAspect) {
            // キャンバスが横長 → 縦にフィット
            fitScale = uniforms.canvasHeight / uniforms.layerHeight;
        } else {
            // キャンバスが縦長 → 横にフィット
            fitScale = uniforms.canvasWidth / uniforms.layerWidth;
        }
        float scaledLayerW = uniforms.layerWidth * fitScale;
        float scaledLayerH = uniforms.layerHeight * fitScale;
        centered.x *= uniforms.canvasWidth / scaledLayerW;
        centered.y *= uniforms.canvasHeight / scaledLayerH;
    }

    // 反転
    if (uniforms.flipH != 0) { centered.x = -centered.x; }
    if (uniforms.flipV != 0) { centered.y = -centered.y; }

    // 0-1に戻す
    return centered + 0.5;
}

// MARK: - シャープネス（3x3ラプラシアンカーネル）

float4 applySharpen(texture2d<float> tex, float2 uv, float sharpness) {
    if (sharpness < 0.001) {
        return tex.sample(sampler(mag_filter::linear, min_filter::linear), uv);
    }

    float2 texelSize = 1.0 / float2(tex.get_width(), tex.get_height());
    constexpr sampler s(mag_filter::linear, min_filter::linear);

    // 3x3 ラプラシアンカーネル
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

/// 1レイヤーを既存のキャンバステクスチャに合成する
fragment float4 editorCompositeFragment(
    EditorVertexOut in [[stage_in]],
    texture2d<float> canvasTexture [[texture(0)]],   // 現在のキャンバス（下のレイヤーまでの合成結果）
    texture2d<float> layerTexture [[texture(1)]],    // 合成するレイヤー
    constant EditorLayerUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // 既存キャンバスの色を取得
    float4 baseColor = canvasTexture.sample(s, in.uv);

    // レイヤーのUV座標を変形
    float2 layerUV = transformUV(in.uv, uniforms);

    // UVが範囲外ならキャンバスの色をそのまま返す
    if (layerUV.x < 0.0 || layerUV.x > 1.0 || layerUV.y < 0.0 || layerUV.y > 1.0) {
        return baseColor;
    }

    // レイヤーテクスチャからサンプリング（シャープネス付き）
    float4 layerColor;
    if (uniforms.sharpness > 0.001) {
        layerColor = applySharpen(layerTexture, layerUV, uniforms.sharpness);
    } else {
        layerColor = layerTexture.sample(s, layerUV);
    }

    // 画像調整を適用
    layerColor = applyAdjustments(layerColor, uniforms);

    // ブレンドモードで合成
    float3 blended = blendColors(baseColor.rgb, layerColor.rgb, uniforms.blendMode);

    // 不透明度とレイヤーアルファを適用
    float finalAlpha = layerColor.a * uniforms.opacity;
    float3 result = mix(baseColor.rgb, blended, finalAlpha);

    // 出力アルファ: Porter-Duff over演算
    float resultAlpha = finalAlpha + baseColor.a * (1.0 - finalAlpha);

    return float4(result, resultAlpha);
}

// MARK: - キャンバスクリアシェーダー

/// キャンバスを指定色でクリア
fragment float4 editorClearFragment(
    EditorVertexOut in [[stage_in]]
) {
    // 透明な背景
    return float4(0.0, 0.0, 0.0, 0.0);
}

// MARK: - プレビュー表示シェーダー

/// 合成済みテクスチャをそのまま表示（チェッカーボード付き透明表示）
fragment float4 editorPreviewFragment(
    EditorVertexOut in [[stage_in]],
    texture2d<float> compositeTexture [[texture(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 color = compositeTexture.sample(s, in.uv);

    // 透明部分にチェッカーボードを表示
    if (color.a < 1.0) {
        float2 pixelPos = in.uv * float2(compositeTexture.get_width(), compositeTexture.get_height());
        float checkerSize = 8.0;
        int cx = int(floor(pixelPos.x / checkerSize));
        int cy = int(floor(pixelPos.y / checkerSize));
        float checker = ((cx + cy) % 2 == 0) ? 0.85 : 0.75;
        float3 checkerColor = float3(checker);

        // アルファブレンド
        color.rgb = mix(checkerColor, color.rgb, color.a);
        color.a = 1.0;
    }

    return color;
}
