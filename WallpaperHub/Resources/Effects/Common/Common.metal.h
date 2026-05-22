// Common.metal.h
// 全 Metal シェーダーで共有する型・サンプラ・関数宣言を集約。
// Why: 旧 Shaders.metal を Resources/Effects/<EffectName>/<EffectName>.metal の
// per-effect 構成へ分割するため、共通の構造体定義と前方宣言を1ヶ所に集める。
#pragma once

#include <metal_stdlib>
using namespace metal;

// =============================================================================
// MARK: - 頂点出力
// =============================================================================
struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// =============================================================================
// MARK: - Uniforms（Swift側と完全一致を保証）
// メモリレイアウト: 96バイト、16バイトアライメント
// =============================================================================
struct Uniforms {
    float time;
    float _pad0;             // resolution用8バイトアライメント
    float2 resolution;
    int shaderType;
    int hasBackgroundImage;  // 背景画像があるかどうか
    float effectIntensity;   // エフェクトの強度 (0.0 - 1.0)
    float _pad1;             // mousePosition用8バイトアライメント
    float2 mousePosition;    // クリック位置 (0-1 normalized)
    float clickTime;         // 最後のクリックからの経過時間
    int clickActive;         // クリックがアクティブかどうか
    int octaveCount;         // FBMオクターブ数 (2-5)
    int hasMaskTexture;      // マスクテクスチャがあるかどうか
    int spanWallpaperAcrossDisplays;
    int _pad2;               // 16バイト境界用パディング
    float2 displayOrigin;    // 仮想キャンバス上のディスプレイ左上
    float2 displaySize;      // 仮想キャンバス上のディスプレイサイズ
    float2 canvasSize;       // 仮想キャンバス全体サイズ
    float2 _pad3;            // 16バイト境界用パディング
};

// =============================================================================
// MARK: - エフェクト用 Uniforms（Swift の RendererEffectUniforms と一致）
// =============================================================================
struct EffectUniforms {
    // パーティクル (32 bytes)
    int particleEnabled;
    int particleStyle;           // 0=雨, 1=雪
    float particleDensity;
    float particleSpeed;
    float particleWindAngle;
    float particleSize;
    float particleOpacity;
    float _pad1;                 // パディング

    // ぼかし (16 bytes)
    int blurEnabled;
    float blurIntensity;
    int blurUseMask;
    float _pad2;                 // パディング

    // ウェーブ (32 bytes)
    int waveEnabled;
    float waveAmplitude;
    float waveFrequency;
    float waveSpeed;
    int waveUseMask;
    int _pad3;                   // パディング
    int _pad4;                   // パディング
    int _pad5;                   // パディング

    // 色収差 (16 bytes)
    int chromaticEnabled;
    float chromaticIntensity;
    float chromaticAngle;
    float _pad6;                 // パディング

    // グリッチ (16 bytes)
    int glitchEnabled;
    float glitchIntensity;
    float glitchSpeed;
    float glitchBlockSize;

    // ビネット (16 bytes)
    int vignetteEnabled;
    float vignetteIntensity;
    float vignetteRadius;
    float _pad7;                 // パディング

    // ピクセレート (16 bytes)
    int pixelateEnabled;
    float pixelateSize;
    float _pad8;                 // パディング
    float _pad9;                 // パディング

    // ブルーム (16 bytes)
    int bloomEnabled;
    float bloomIntensity;
    float bloomThreshold;
    float _pad10;                // パディング

    // 陽炎 (16 bytes)
    int heatHazeEnabled;
    float heatHazeIntensity;
    float heatHazeSpeed;
    float heatHazeScale;

    // 水面波紋 (32 bytes)
    int waterRippleEnabled;
    float waterRippleIntensity;
    float waterRippleSpeed;
    float waterRippleScale;
    float waterRippleReflection;
    int waterRippleUseMask;
    float _pad11;                    // パディング
    float _pad12;                    // パディング

    // 植物揺れ (32 bytes)
    int foliageSwayEnabled;
    float foliageSwayIntensity;
    float foliageSwaySpeed;
    float foliageSwayComplexity;
    int foliageSwayUseMask;
    int _pad13;                      // パディング
    int _pad14;                      // パディング
    int _pad15;                      // パディング
};

// =============================================================================
// MARK: - 共通ユーティリティ（Common/Common.metal で実装）
// ノイズ/FBM、アスペクト比 UV 変換は複数エフェクトから参照される。
// =============================================================================
half hash_h(half2 p);
half noise_h(half2 p);
float noise(float2 p);
half fbm_h(half2 p, int octaves);
float fbm(float2 p, int octaves);
float2 aspectFillUV(float2 uv, float2 screenSize, float2 textureSize);
float2 aspectFitUV(float2 uv, float2 screenSize, float2 textureSize);

// =============================================================================
// MARK: - 背景シェーダー（GradientWave / Plasma / NoiseFlow）
// =============================================================================
float3 gradientWave(float2 uv, float time);
float3 plasma(float2 uv, float time);
float3 noiseFlow(float2 uv, float time, int octaves);

// =============================================================================
// MARK: - 歪み系エフェクト（Wave / HeatHaze / WaterRipple / FoliageSway）
// =============================================================================
float2 waveDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                      constant EffectUniforms &fx, int hasMask);
float2 heatHazeDistortion(float2 uv, float time, constant EffectUniforms &fx);
float2 waterRippleDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                             constant EffectUniforms &fx, int hasMask);
float2 foliageSwayDistortion(float2 uv, float time, texture2d<float> maskTex, sampler s,
                             constant EffectUniforms &fx, int hasMask);

// =============================================================================
// MARK: - ポストエフェクト（Blur / ChromaticAberration / Glitch / Vignette / Pixelate / Bloom / WaterRipple 反射）
// =============================================================================
float3 gaussianBlur(texture2d<float> tex, sampler s, float2 uv, float2 resolution, float intensity);
float3 blurEffect(texture2d<float> tex, texture2d<float> maskTex, sampler s,
                  float2 uv, float2 resolution, constant EffectUniforms &fx,
                  float3 baseColor, int hasMask);
float3 chromaticAberration(texture2d<float> tex, sampler s, float2 uv,
                           constant EffectUniforms &fx, float3 baseColor);
float3 glitchEffect(texture2d<float> tex, sampler s, float2 uv, float time,
                    constant EffectUniforms &fx, float3 baseColor);
float3 vignetteEffect(float2 uv, constant EffectUniforms &fx, float3 baseColor);
float2 pixelateUV(float2 uv, constant EffectUniforms &fx);
float3 bloomEffect(texture2d<float> tex, sampler s, float2 uv, float2 resolution,
                   constant EffectUniforms &fx, float3 baseColor);
float3 waterRippleReflection(float2 uv, float time, constant EffectUniforms &fx, float3 baseColor);

// =============================================================================
// MARK: - パーティクル系（Particle / ClickRipple）
// =============================================================================
float2 particleHash(float2 p);
float3 particleEffect(float2 uv, float time, constant EffectUniforms &fx, float3 baseColor);
float3 clickRipple(float2 uv, float2 clickPos, float clickTime, float3 baseColor);
