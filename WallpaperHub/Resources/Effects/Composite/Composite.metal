// Composite.metal
// vertexShader と fragmentShader 本体（パイプラインのエントリポイント）。
// Why: 各エフェクトファイルから純粋関数を呼び出すだけの「合成オーケストレーション」役を
// 1ファイルに分離。
//
// Phase 1.2+ 改修:
//   - shaderType を Function Constant 化 (kShaderType) し、PSO バリアント単位で
//     使われない分岐をコンパイル時に dead code 除去する。
//   - effectIntensity の「>0.0 で全エフェクト有効化」隠しゲートを撤去し、
//     各エフェクトは <name>Enabled フラグのみで判定する。effectIntensity は
//     最終 procedural ミックス比率専用に意味を狭める。
//
// 重要な設計原則（座標系の二系統管理）:
//   - 背景画像サンプリング = bgUV（aspect fill。画面を埋めるため画像が一部はみ出す）
//   - マスクサンプリング   = maskUV（aspect fit。画像全体が見える＝MaskEditor と同じ座標）
//   この2系統を分けないと、画像座標で塗ったマスクが画面に対してズレた位置で参照され、
//   「中央に描いたのに右端がねじれる」というバグになる。
//
//   歪み量(dx, dy) は中心相対(0,0)〜(1,1)の UV 単位で計算され、
//   bgUV/maskUV それぞれに同じ量を加算する（中心からの相対位置は両系統で線形対応するため、
//   小さい歪みであれば見た目もほぼ揃う）。
#include "../Common/Common.metal.h"

// MARK: - Function Constants
// シェーダ種別: 0=transparent, 1=gradientWave, 2=plasma, 3=noiseFlow
// MTLFunctionConstantValues で PSO 生成時にバリアントを束縛する。
// Renderer.swift 側で 4 種の PSO を事前ビルドし、currentShader.rawValue で選択する。
constant int kShaderType [[function_constant(0)]];

// 頂点シェーダー
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                              constant float4 *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = vertices[vertexID];
    out.uv = (vertices[vertexID].xy + 1.0) * 0.5;
    out.uv.y = 1.0 - out.uv.y; // Y軸反転
    return out;
}

// プロシージャル背景の選択（Function Constant でコンパイル時分岐）
// kShaderType が 0 の場合は呼び出し側で透過分岐に分岐済みのため、ここでは 1..3 のみ生成。
static inline float3 sampleProceduralBackground(float2 uv, float time, int octaveCount) {
    if (kShaderType == 1) {
        return gradientWave(uv, time);
    } else if (kShaderType == 2) {
        return plasma(uv, time);
    } else if (kShaderType == 3) {
        return noiseFlow(uv, time, octaveCount);
    } else {
        return float3(0.0);
    }
}

// フラグメントシェーダー
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(0)]],
                               constant EffectUniforms &effectUniforms [[buffer(1)]],
                               texture2d<float> backgroundTexture [[texture(0)]],
                               texture2d<float> maskTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // 画面 UV（出力先のフラグメント座標）
    float2 screenUV = in.uv;
    float2 quantizedScreenUV = pixelateUV(screenUV, effectUniforms);

    // kShaderType は Function Constant のためコンパイル時に既知。透過 PSO では
    // この分岐ブロックのみが残り、それ以外は dead code 除去される。
    bool isTransparentShader = (kShaderType == 0);

    // 透過シェーダーで背景画像がない場合は完全透明（パーティクル等のみ重ね描き）
    if (isTransparentShader && uniforms.hasBackgroundImage == 0) {
        float3 overlayColor = float3(0.0);
        float overlayAlpha = 0.0;

        float3 particleResult = particleEffect(screenUV, uniforms.time, effectUniforms, float3(0.0));
        float particleAlpha = length(particleResult);
        if (particleAlpha > 0.001) {
            overlayColor = particleResult;
            overlayAlpha = saturate(particleAlpha);
        }

        if (uniforms.clickActive != 0) {
            float3 rippleResult = clickRipple(screenUV, uniforms.mousePosition, uniforms.clickTime, overlayColor);
            float rippleDiff = length(rippleResult - overlayColor);
            if (rippleDiff > 0.001) {
                overlayColor = rippleResult;
                overlayAlpha = saturate(overlayAlpha + rippleDiff);
            }
        }

        return float4(overlayColor, overlayAlpha);
    }

    float outputAlpha = 1.0;
    float3 effectColor;

    // ─────────────────────────────────────────────────────────────
    // 背景画像がある場合: bgUV(fill) と maskUV(fit) を別々に確定
    // ─────────────────────────────────────────────────────────────
    if (uniforms.hasBackgroundImage != 0) {
        float2 textureSize = float2(backgroundTexture.get_width(), backgroundTexture.get_height());
        float2 wallpaperUV = quantizedScreenUV;
        float2 wallpaperScreenSize = uniforms.resolution;

        if (uniforms.spanWallpaperAcrossDisplays != 0 &&
            uniforms.canvasSize.x > 0.0 &&
            uniforms.canvasSize.y > 0.0 &&
            uniforms.displaySize.x > 0.0 &&
            uniforms.displaySize.y > 0.0) {
            float2 virtualPixel = uniforms.displayOrigin + quantizedScreenUV * uniforms.displaySize;
            wallpaperUV = virtualPixel / uniforms.canvasSize;
            wallpaperScreenSize = uniforms.canvasSize;
        }

        // 2系統の UV を確定:
        //   bgUV   = 画面を埋めるための fill 座標（背景サンプル用）
        //   maskUV = 画像全体が見える fit 座標（マスクサンプル用、MaskEditor と一致）
        float2 bgUV   = aspectFillUV(wallpaperUV, wallpaperScreenSize, textureSize);
        float2 maskUV = aspectFitUV (wallpaperUV, wallpaperScreenSize, textureSize);

        // 重要: maskUV が画像範囲外（=画面の黒帯部分）の場合は歪みを 0 にする。
        bool maskUVInsideImage = all(maskUV >= float2(0.0)) && all(maskUV <= float2(1.0));

        // 歪み量は maskUV を入力にして計算（マスクサンプル位置と歪み計算位置を一致させる）。
        float2 distortionDelta = float2(0.0);
        if (maskUVInsideImage) {
            // wave
            {
                float2 d = waveDistortion(maskUV, uniforms.time, maskTexture, textureSampler,
                                           effectUniforms, uniforms.hasMaskTexture) - maskUV;
                distortionDelta += d;
            }
            // heatHaze（マスク非依存だが画像範囲内に揃える）
            {
                float2 d = heatHazeDistortion(maskUV, uniforms.time, effectUniforms) - maskUV;
                distortionDelta += d;
            }
            // waterRipple
            {
                float2 d = waterRippleDistortion(maskUV, uniforms.time, maskTexture, textureSampler,
                                                  effectUniforms, uniforms.hasMaskTexture) - maskUV;
                distortionDelta += d;
            }
            // foliageSway
            {
                float2 d = foliageSwayDistortion(maskUV, uniforms.time, maskTexture, textureSampler,
                                                  effectUniforms, uniforms.hasMaskTexture) - maskUV;
                distortionDelta += d;
            }
        }

        float2 distortedBgUV = bgUV + distortionDelta;

        // aspect fill は仕様上 bgUV が 0..1 を超える領域を持つ（画像が画面からはみ出す部分）。
        // sampler の clamp_to_edge で端の色が伸びるが、それを許容して常にサンプルする。
        float4 bgSample = backgroundTexture.sample(textureSampler, distortedBgUV);
        float3 bgColor = bgSample.rgb;
        float bgAlpha = bgSample.a;

        // Phase 1.2+: 各ポストエフェクトは内部で <name>Enabled を見ているので
        // 旧 if (intensity > 0.0) のグローバルゲートは廃止。
        // 個別エフェクトを enable=false にすれば中で no-op で抜ける設計。
        if (effectUniforms.blurEnabled != 0) {
            bgColor = blurEffect(backgroundTexture, maskTexture, textureSampler,
                                 distortedBgUV, uniforms.resolution, effectUniforms,
                                 bgColor, uniforms.hasMaskTexture);
        }
        bgColor = chromaticAberration(backgroundTexture, textureSampler, distortedBgUV,
                                      effectUniforms, bgColor);
        bgColor = glitchEffect(backgroundTexture, textureSampler, distortedBgUV, uniforms.time,
                               effectUniforms, bgColor);
        bgColor = bloomEffect(backgroundTexture, textureSampler, distortedBgUV, uniforms.resolution,
                              effectUniforms, bgColor);
        bgColor = waterRippleReflection(distortedBgUV, uniforms.time, effectUniforms, bgColor);

        if (isTransparentShader) {
            // 透過 PSO: プロシージャル背景は使わない
            effectColor = bgColor;
            outputAlpha = bgAlpha;
        } else {
            // procedural PSO: kShaderType に応じてプロシージャル背景を生成
            float3 procedural = sampleProceduralBackground(quantizedScreenUV, uniforms.time, uniforms.octaveCount);
            // effectIntensity = bg と procedural のグローバルミックス比率（再定義後の唯一の役割）
            effectColor = mix(bgColor, procedural, uniforms.effectIntensity);
        }
    } else {
        // 背景画像なし & 非透過 PSO: プロシージャル背景のみ
        effectColor = sampleProceduralBackground(quantizedScreenUV, uniforms.time, uniforms.octaveCount);
    }

    // 画面全体に被せる装飾系（画面 UV ベース）
    effectColor = particleEffect(screenUV, uniforms.time, effectUniforms, effectColor);
    effectColor = vignetteEffect(screenUV, effectUniforms, effectColor);
    if (uniforms.clickActive != 0) {
        effectColor = clickRipple(screenUV, uniforms.mousePosition, uniforms.clickTime, effectColor);
    }

    if (isTransparentShader && uniforms.hasBackgroundImage != 0) {
        outputAlpha = saturate(max(outputAlpha, length(effectColor) > 0.001 ? outputAlpha : 0.0));
    }

    return float4(effectColor, outputAlpha);
}
