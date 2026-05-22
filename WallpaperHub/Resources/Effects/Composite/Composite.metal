#include "../Common/Common.metal.h"

// MARK: - Function Constants
constant int kShaderType [[function_constant(0)]];

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                              constant float4 *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = vertices[vertexID];
    out.uv = (vertices[vertexID].xy + 1.0) * 0.5;
    out.uv.y = 1.0 - out.uv.y; // Y軸反転
    return out;
}

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

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant Uniforms &uniforms [[buffer(0)]],
                               constant EffectUniforms &effectUniforms [[buffer(1)]],
                               texture2d<float> backgroundTexture [[texture(0)]],
                               texture2d<float> maskTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 screenUV = in.uv;
    float2 quantizedScreenUV = pixelateUV(screenUV, effectUniforms);

    bool isTransparentShader = (kShaderType == 0);

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

        float2 bgUV   = aspectFillUV(wallpaperUV, wallpaperScreenSize, textureSize);
        float2 maskUV = aspectFitUV (wallpaperUV, wallpaperScreenSize, textureSize);

        bool maskUVInsideImage = all(maskUV >= float2(0.0)) && all(maskUV <= float2(1.0));

        float2 distortionDelta = float2(0.0);
        if (maskUVInsideImage) {
            {
                float2 d = waveDistortion(maskUV, uniforms.time, maskTexture, textureSampler,
                                           effectUniforms, uniforms.hasMaskTexture) - maskUV;
                distortionDelta += d;
            }
            {
                float2 d = heatHazeDistortion(maskUV, uniforms.time, effectUniforms) - maskUV;
                distortionDelta += d;
            }
            {
                float2 d = waterRippleDistortion(maskUV, uniforms.time, maskTexture, textureSampler,
                                                  effectUniforms, uniforms.hasMaskTexture) - maskUV;
                distortionDelta += d;
            }
            {
                float2 d = foliageSwayDistortion(maskUV, uniforms.time, maskTexture, textureSampler,
                                                  effectUniforms, uniforms.hasMaskTexture) - maskUV;
                distortionDelta += d;
            }
        }

        float2 distortedBgUV = bgUV + distortionDelta;

        float4 bgSample = backgroundTexture.sample(textureSampler, distortedBgUV);
        float3 bgColor = bgSample.rgb;
        float bgAlpha = bgSample.a;

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
            effectColor = bgColor;
            outputAlpha = bgAlpha;
        } else {
            float3 procedural = sampleProceduralBackground(quantizedScreenUV, uniforms.time, uniforms.octaveCount);
            effectColor = mix(bgColor, procedural, uniforms.effectIntensity);
        }
    } else {
        effectColor = sampleProceduralBackground(quantizedScreenUV, uniforms.time, uniforms.octaveCount);
    }

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
