// パーティクルシステム (Phase 4A)
// Why: emitter / initializer / operator の 3 段構成 + 固定 65536 スロットの particle 配列で、
//      Wallpaper Engine 互換の最小パーティクルシステムを構築する。
//      Phase 4A は CPU simulation を authoritative とし、tests から完全に再現可能にする。
//      GPU compute kernel は WGSL を同梱し、後続フェーズで dispatch を有効化する。

mod compute;
pub mod emitter;
pub mod initializer;
pub mod operator;
// `particle` module は本ディレクトリと同名だが、Particle 型を `super::particle::Particle` で
// 明示参照させたく、`mod data` 等にリネームしないでおく。clippy::module_inception はここでは許容する。
#[allow(clippy::module_inception)]
pub mod particle;
mod render;
mod rng;

#[cfg(test)]
mod tests;

use serde::{Deserialize, Serialize};

pub use compute::PARTICLE_SIMULATE_WGSL;
pub use emitter::{Emitter, EmitterDescriptor, EmitterShape};
pub use initializer::{Initializer, InitializerDescriptor};
pub use operator::{Operator, OperatorDescriptor};
pub use particle::Particle;
pub use render::PARTICLE_RENDER_WGSL;

/// パーティクル数の固定上限。
/// Why: GPU storage buffer を確保する都合上、ringbuffer 的な動的拡張は行わない。
///      ライセンスフリーで動かせる規模感で 65536 (= 2^16) を採用。
pub const MAX_PARTICLES: usize = 65536;

/// ParticleSystem の識別子。FFI で u32 ハンドルとして公開する。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ParticleSystemId(pub u32);

/// 1 つの ParticleSystem の生成パラメータ。
/// Why: Swift 側で構築し JSON で渡されることを想定する。
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ParticleSystemDescriptor {
    /// 同時生存できる particle 上限。`MAX_PARTICLES` で clamp される。
    #[serde(default = "default_capacity")]
    pub capacity: u32,
    /// 乱数シード。決定論性が必要なテスト/プレビューで指定する。
    #[serde(default = "default_seed")]
    pub seed: u64,
    pub emitter: EmitterDescriptor,
    #[serde(default)]
    pub initializers: Vec<InitializerDescriptor>,
    #[serde(default)]
    pub operators: Vec<OperatorDescriptor>,
}

fn default_capacity() -> u32 { 1024 }
fn default_seed() -> u64 { 0x9E37_79B9_7F4A_7C15 }

/// `update_particle_system` で送る差分パラメータ。
/// Why: 一部だけ差し替えたいユースケース (例: ユーザー UI で重力だけ更新) に対応する。
#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct ParticleSystemParams {
    #[serde(default)]
    pub emitter: Option<EmitterDescriptor>,
    #[serde(default)]
    pub initializers: Option<Vec<InitializerDescriptor>>,
    #[serde(default)]
    pub operators: Option<Vec<OperatorDescriptor>>,
}

/// パーティクルシステム本体。CPU simulation を保有する。
pub struct ParticleSystem {
    pub id: ParticleSystemId,
    pub capacity: usize,
    pub emitter: Emitter,
    pub initializers: Vec<Initializer>,
    pub operators: Vec<Operator>,
    /// 固定長 particle 配列。`is_dead()` のスロットが空き枠。
    pub particles: Vec<Particle>,
    /// 経過時間 (秒)。
    pub elapsed: f32,
    /// 決定論的乱数の状態。
    pub rng_state: u64,
    /// 直近 1 step で実際に spawn した数 (テスト用にメトリクス保持)。
    pub last_spawn_count: u32,
    /// 直近 1 step で kill した数。
    pub last_kill_count: u32,
    /// Phase 6A: emitter spawn_rate に audio バンドを加算するためのバインド (None なら未適用)。
    pub audio_binding: Option<crate::audio::EmitterAudioBinding>,
}

impl ParticleSystem {
    /// 新規システムを構築する。
    pub fn new(id: ParticleSystemId, descriptor: ParticleSystemDescriptor) -> Self {
        let capacity = (descriptor.capacity as usize).clamp(1, MAX_PARTICLES);
        let particles = vec![Particle::default(); capacity];
        Self {
            id,
            capacity,
            emitter: Emitter::from_descriptor(descriptor.emitter),
            initializers: descriptor.initializers,
            operators: descriptor.operators,
            particles,
            elapsed: 0.0,
            rng_state: descriptor.seed,
            last_spawn_count: 0,
            last_kill_count: 0,
            audio_binding: None,
        }
    }

    /// 部分更新を反映する。
    pub fn apply_params(&mut self, params: ParticleSystemParams) {
        if let Some(d) = params.emitter {
            // burst_pending / spawn_accumulator は新しい descriptor 由来でリセットする。
            self.emitter = Emitter::from_descriptor(d);
        }
        if let Some(inits) = params.initializers {
            self.initializers = inits;
        }
        if let Some(ops) = params.operators {
            self.operators = ops;
        }
    }

    /// 現在生存中のパーティクル数。
    pub fn alive_count(&self) -> usize {
        self.particles.iter().filter(|p| !p.is_dead()).count()
    }

    /// Phase 6A: audio uniform を考慮した 1 ステップシミュレーション。
    /// Why: emit rate を `audio_binding` で変調するため、emitter.spawn_rate を一時的に差し替える。
    pub fn simulate_cpu_with_audio(&mut self, dt: f32, audio: &crate::audio::AudioUniform) {
        if let Some(binding) = self.audio_binding {
            let original = self.emitter.spawn_rate;
            self.emitter.spawn_rate = binding.modulated_rate(original, audio);
            self.simulate_cpu(dt);
            self.emitter.spawn_rate = original;
        } else {
            self.simulate_cpu(dt);
        }
    }

    /// 1 ステップ進める CPU シミュレーション。
    ///
    /// Why: GPU compute kernel と同じロジックを Rust 側で実装することで、テストでも
    ///      決定論的に挙動を検証できる。GPU 経路 (後続フェーズ) はこの関数のロジックを
    ///      WGSL に転記する想定。
    pub fn simulate_cpu(&mut self, dt: f32) {
        if dt <= 0.0 {
            return;
        }
        self.elapsed += dt;

        // 1. 既存パーティクルを進める。
        //    順序: age += dt → operators 適用 (gravity 等で速度を更新) → 位置を新速度で積分 → kill 判定。
        //    Why: semi-implicit Euler の方が gravity 等を直近フレームから反映でき、テストとも一致する。
        let mut kill_count = 0u32;
        for p in self.particles.iter_mut() {
            if p.is_dead() {
                continue;
            }
            p.age += dt;
            let mut alive = true;
            for op in &self.operators {
                if !op.apply(p, dt) {
                    alive = false;
                    break;
                }
            }
            if alive {
                p.position[0] += p.velocity[0] * dt;
                p.position[1] += p.velocity[1] * dt;
            }
            if !alive || p.is_dead() {
                p.lifetime = 0.0;
                kill_count += 1;
            }
        }
        self.last_kill_count = kill_count;

        // 2. 新規 spawn: emitter から「この dt で何匹出すか」を取得し、空きスロットに詰める
        let mut spawn_remaining = self.emitter.pop_spawn_count(dt);
        let mut spawn_count = 0u32;
        if spawn_remaining > 0 {
            for p in self.particles.iter_mut() {
                if spawn_remaining == 0 {
                    break;
                }
                if !p.is_dead() {
                    continue;
                }
                *p = Particle::default();
                p.position = self.emitter.sample_position(&mut self.rng_state);
                // initializers を順番に適用。VelocityCone と RandomDirection は同時に書くと
                // 後者が勝つが、それは Wallpaper Engine 仕様 (列挙順優先) と同じ。
                for init in &self.initializers {
                    init.apply(p, &mut self.rng_state);
                }
                if p.lifetime <= 0.0 {
                    // lifetime 未設定なら一旦 1 秒で逃がす (タイムアウト用)。
                    p.lifetime = 1.0;
                }
                spawn_remaining -= 1;
                spawn_count += 1;
            }
        }
        self.last_spawn_count = spawn_count;
    }
}
