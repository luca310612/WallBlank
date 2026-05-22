// GPU compute pipeline 設定 (Phase 4A: scaffolding)
// Why: 最終的に WGSL kernel `particle_simulate.wgsl` で全 particle を並列に進めるための
//      pipeline / bind group をホストする予定。Phase 4A では CPU simulation を真の挙動として
//      ロックし、GPU 経路は後続フェーズで dispatch まで実装する。

/// `particle_simulate.wgsl` の生ソース。
/// Why: 後続フェーズで `device.create_shader_module` に渡す。compile を CI で検証できるよう
///      `include_str!` で取り込み、最終バイナリにも含めておく。
pub const PARTICLE_SIMULATE_WGSL: &str = include_str!("../shaders/particle/particle_simulate.wgsl");
