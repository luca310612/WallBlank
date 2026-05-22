// Phase 4C: パペットワープの制御点 (handle)
// Why: anchor (固定点) と pin (ドラッグで動かす点) を区別せず、
//      源座標 source と目標座標 target を持つだけで RBF/IDW の入力として扱える。
//      anchor は target == source で表現するため、enum を構造体に潰している。

use serde::{Deserialize, Serialize};

/// 制御点の種別。
/// - Anchor: 固定点。RBF 入力では `target == source` として扱う。
/// - Pin: ドラッグで動かす制御点。`target` がドラッグ後の位置。
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HandleKind {
    Anchor,
    Pin,
}

/// 制御点定義。Swift `PuppetWarpHandleDescriptor` と JSON 互換。
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct HandleDescriptor {
    pub kind: HandleKind,
    /// 元の位置 (レイヤー画像座標 px)
    pub source: [f32; 2],
    /// 変形後の位置 (レイヤー画像座標 px)。
    /// anchor の場合は `source` と同値で渡される。
    pub target: [f32; 2],
}

impl HandleDescriptor {
    /// 変位ベクトル (target - source)。
    pub fn displacement(&self) -> [f32; 2] {
        [self.target[0] - self.source[0], self.target[1] - self.source[1]]
    }
}
