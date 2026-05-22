// パーティクルレンダリング (Phase 4A: scaffolding)
// Why: instanced quad で alpha-blended sprite を描く WGSL を持つ。
//      Phase 4A では shader 文字列を保持するのみ、render pipeline 構築は後続フェーズで行う。

/// `particle_render.wgsl` の生ソース。後続フェーズで `device.create_shader_module` に渡す。
pub const PARTICLE_RENDER_WGSL: &str = include_str!("../shaders/particle/particle_render.wgsl");
