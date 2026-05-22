// 軽量 Xorshift64 RNG
// Why: パーティクル初期化の決定論性をテストで担保したいので、`rand` クレート依存を増やさず
//      32-bit float 乱数を最小コードで生成する。

/// Xorshift64 1 step。state は非ゼロを保つこと。
#[inline]
pub fn next_u64(state: &mut u64) -> u64 {
    let mut x = *state;
    if x == 0 {
        // 0 状態は周期 0 となるためデフォルトシードへ復帰させる。
        x = 0x9E37_79B9_7F4A_7C15;
    }
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

/// [0.0, 1.0) の f32 乱数。
#[inline]
pub fn next_f32_unit(state: &mut u64) -> f32 {
    let v = next_u64(state) >> 40; // 24bit
    (v as f32) / ((1u32 << 24) as f32)
}

/// [min, max] の f32 乱数。`min == max` のときは min を返す。
#[inline]
pub fn next_f32_range(state: &mut u64, min: f32, max: f32) -> f32 {
    if (max - min).abs() < f32::EPSILON {
        return min;
    }
    let lo = min.min(max);
    let hi = min.max(max);
    lo + next_f32_unit(state) * (hi - lo)
}
