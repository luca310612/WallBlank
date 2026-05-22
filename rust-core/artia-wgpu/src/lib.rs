// Artia WGPUアニメーションエンジン
// 静的画像にアニメーションを付与するヘッドレスGPUレンダラー

mod engine;
mod iosurface;
mod types;
mod layer;
mod compositor;
mod motion;
pub mod animation;
pub mod audio;
pub mod bone;
pub mod light;
pub mod parallax;
pub mod particle;
pub mod spanning;
pub mod warp;

pub use engine::{WgpuEngine, RenderStatus, RENDER_OK, RENDER_ERROR};
pub use types::{BlendMode, EditorTransform, ImageAdjustments, LayerTransform};
pub use animation::{AnimationConfig, AnimationPreset, TransformDelta};
pub use audio::{AudioUniform, EmitterAudioBinding, AUDIO_WGSL, MAX_AUDIO_BANDS};
pub use bone::{
    BoneDescriptor, Mat4 as BoneMat4, Skeleton, SkeletonDescriptor, SkeletonId,
    SkeletonPoseParams, VertexWeights, SKIN_WGSL,
};
pub use light::{
    LightLayer, LightLayerDescriptor, LightLayerId, LightLayerParams, LIGHT_WGSL,
};
pub use motion::{FlowField, FlowFieldParams};
pub use parallax::{NormalizedMouseOffset, ParallaxLayerSetting};
pub use spanning::{DisplaySpan, SpanningCanvas, SpanningError};
pub use particle::{
    EmitterDescriptor, EmitterShape, InitializerDescriptor, OperatorDescriptor, Particle,
    ParticleSystem, ParticleSystemDescriptor, ParticleSystemId, ParticleSystemParams,
    MAX_PARTICLES, PARTICLE_RENDER_WGSL, PARTICLE_SIMULATE_WGSL,
};
pub use warp::{
    HandleDescriptor, HandleKind, PuppetWarp, PuppetWarpDescriptor, PuppetWarpId,
    PuppetWarpParams, WARP_WGSL,
};