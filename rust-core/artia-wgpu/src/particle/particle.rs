// パーティクル POD 構造体
// Why: GPU storage buffer に転送する都合上、`#[repr(C)]` + 16-byte aligned レイアウトで保持する。
//      WGSL 側 (`particle_simulate.wgsl`) と同じバイトレイアウトを共有する。

use bytemuck::{Pod, Zeroable};

/// シミュレーション 1 個のパーティクル。
/// Why: WGSL 側と layout を一致させるため位置/速度/色/寿命を一直線に並べる。
///      末尾の `_pad` は 16 バイトアラインを担保する。
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct Particle {
    /// 位置 (canvas pixel 座標、左下原点)
    pub position: [f32; 2],
    /// 速度 (pixel / second)
    pub velocity: [f32; 2],
    /// 色 (RGBA, 0.0 - 1.0)
    pub color: [f32; 4],
    /// サイズ (pixel)
    pub size: f32,
    /// 経過時間 (秒)
    pub age: f32,
    /// 寿命 (秒)。`age >= lifetime` で死亡判定。
    pub lifetime: f32,
    /// 16-byte アライン用パディング。
    pub _pad: f32,
}

impl Particle {
    /// 死亡しているかどうか。
    /// Why: lifetime <= 0.0 のスロットは未使用 (空き) として扱う方針なので
    ///      "未使用" と "寿命切れ" を一括で扱える判定にする。
    pub fn is_dead(&self) -> bool {
        self.lifetime <= 0.0 || self.age >= self.lifetime
    }

    /// 寿命に対する正規化進捗 (0.0 - 1.0)。
    /// Why: SizeOverLife / ColorOverLife など寿命線形補間オペレータが共通で使う。
    pub fn life_progress(&self) -> f32 {
        if self.lifetime <= 0.0 {
            0.0
        } else {
            (self.age / self.lifetime).clamp(0.0, 1.0)
        }
    }
}
