
#include <metal_stdlib>
using namespace metal;

// MARK: - DabParams（Swift 側の BrushDabParams と完全一致を保証）
struct DabParams {
    float2 center;       // ダブ中心（ピクセル座標）
    float radius;        // ダブ半径（ピクセル）
    float hardness;      // 0..1
    float opacity;       // 0..1
    float flow;          // 0..1（dab 1 回での寄与率）
    int paintMode;       // 0=normal, 1=add, 2=subtract
    int _pad0;
};

inline float dabFalloff(float distNorm, float hardness) {
    float h = clamp(hardness, 0.0, 1.0);
    float inner = h;            // h より内側は完全不透明
    if (distNorm <= inner) {
        return 1.0;
    }
    float t = (distNorm - inner) / max(1e-4, 1.0 - inner);
    return 1.0 - smoothstep(0.0, 1.0, t);
}

// MARK: - rasterizeDab
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
        result = min(1.0, current + dabAlpha);
    } else if (params.paintMode == 2) {
        result = max(0.0, current - dabAlpha);
    } else {
        result = current + (1.0 - current) * dabAlpha;
    }

    mask.write(float4(result, 0.0, 0.0, 1.0), gid);
}

// MARK: - clearMask
kernel void clearMask(
    texture2d<float, access::write> mask [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) {
        return;
    }
    mask.write(float4(0.0, 0.0, 0.0, 1.0), gid);
}
