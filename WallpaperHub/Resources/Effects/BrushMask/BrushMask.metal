// BrushMask.metal
// ブラシダブ（1スタンプ）を GPU compute で .r8Unorm マスクへ塗り込む。
// Why: CPU/Rust 側の dab ラスタライズはストローク中にメインスレッドへ波及し、
// UI フレームレートが落ちる。Phase 1.4 では「1 ダブ = 1 dispatch」で GPU 完結させ、
// MTKView 表示・レイヤー合成までテクスチャを CPU に戻さずに流せる基盤を用意する。
//
// 設計方針:
// - 入力ジオメトリは中心座標 + 半径のみ。ストロークは Swift 側で 1 ダブずつ呼び出す。
// - hardness は 0..1 で、円の中心側を不透明・縁を soft にする falloff 制御に使う。
// - opacity / flow は 1 ダブ単位の最終アルファを決める。
// - paintMode: 0=normal/lerp, 1=add, 2=subtract（消しゴム/イレーザ用）。
// - texture(0) は read_write の .r8Unorm。境界外 thread は早期 return。
//
// 既存 Rust 実装との互換は段階的に取る（Phase 1.4 はこの kernel 自体の追加に留める）。

#include <metal_stdlib>
using namespace metal;

// MARK: - DabParams（Swift 側の BrushDabParams と完全一致を保証）
// 16バイト境界アライメントを意識して並べる。
struct DabParams {
    float2 center;       // ダブ中心（ピクセル座標）
    float radius;        // ダブ半径（ピクセル）
    float hardness;      // 0..1
    float opacity;       // 0..1
    float flow;          // 0..1（dab 1 回での寄与率）
    int paintMode;       // 0=normal, 1=add, 2=subtract
    int _pad0;
};

// hardness を反映した円形 falloff（中心=1, 縁=0）。
// hardness=1 で全域不透明、hardness<1 で縁に soft グラデーションを生成する。
inline float dabFalloff(float distNorm, float hardness) {
    // distNorm: 0..1（中心 0, 縁 1）
    float h = clamp(hardness, 0.0, 1.0);
    float inner = h;            // h より内側は完全不透明
    if (distNorm <= inner) {
        return 1.0;
    }
    float t = (distNorm - inner) / max(1e-4, 1.0 - inner);
    // smoothstep 補間（Krita の soft brush に近い形状）
    return 1.0 - smoothstep(0.0, 1.0, t);
}

// MARK: - rasterizeDab
// 1 ダブを mask テクスチャへ書き込む。
// dispatchThreads は (radius*2+1, radius*2+1) のローカル領域に絞ると効率が良いが、
// シンプルさ優先でフルキャンバス dispatch も許容する（境界判定で早期 return）。
kernel void rasterizeDab(
    texture2d<float, access::read_write> mask [[texture(0)]],
    constant DabParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width  = mask.get_width();
    uint height = mask.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float2 pixel = float2(float(gid.x) + 0.5, float(gid.y) + 0.5);
    float dx = pixel.x - params.center.x;
    float dy = pixel.y - params.center.y;
    float dist = sqrt(dx * dx + dy * dy);

    float r = max(0.5, params.radius);
    if (dist > r) {
        return;
    }

    float distNorm = dist / r;
    float falloff = dabFalloff(distNorm, params.hardness);
    float dabAlpha = falloff * clamp(params.opacity, 0.0, 1.0) * clamp(params.flow, 0.0, 1.0);
    if (dabAlpha <= 0.0) {
        return;
    }

    float current = mask.read(gid).r;
    float result = current;

    if (params.paintMode == 1) {
        // add（加算合成、上限 1.0）
        result = min(1.0, current + dabAlpha);
    } else if (params.paintMode == 2) {
        // subtract（イレーザ）
        result = max(0.0, current - dabAlpha);
    } else {
        // normal: 既存値と dabAlpha の lerp（不透明寄せ）
        result = current + (1.0 - current) * dabAlpha;
    }

    mask.write(float4(result, 0.0, 0.0, 1.0), gid);
}

// MARK: - clearMask
// マスク全体を 0 で塗りつぶす（ストローク開始時 / 確定後の初期化用）。
kernel void clearMask(
    texture2d<float, access::write> mask [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) {
        return;
    }
    mask.write(float4(0.0, 0.0, 0.0, 1.0), gid);
}
