// レイヤー管理
// 各レイヤーはGPUテクスチャ・変形・合成パラメータを保持する

use crate::animation::{AnimationConfig, TransformDelta};
use crate::motion::FlowField;
use crate::parallax::ParallaxLayerSetting;
use crate::types::{
    canvas_to_viewport_matrix, invert_mat4, mul_mat4, BlendMode, EditorTransform,
    ImageAdjustments, LayerTransform, LayerUniforms, ViewportParams,
};

/// 1つのレイヤーを表す
pub struct Layer {
    pub id: String,
    pub name: String,
    pub texture: wgpu::Texture,
    pub texture_view: wgpu::TextureView,
    pub bind_group: wgpu::BindGroup,
    pub width: u32,
    pub height: u32,
    pub transform: LayerTransform,
    pub opacity: f32,
    pub blend_mode: BlendMode,
    pub visible: bool,
    pub animation_config: Option<AnimationConfig>,
    pub adjustments: ImageAdjustments,
    /// エディタ用変形（設定時はこちらを優先して行列計算に使用する）
    pub editor_transform: Option<EditorTransform>,
    /// 水流ブラシ用フローフィールド（None = 未使用）
    pub flow_field: Option<FlowField>,
    /// パララックス設定 (Phase 4B)。None = 視差なし。
    pub parallax: Option<ParallaxLayerSetting>,
    /// 直近フレームで計算されたパララックスオフセット (px)。
    /// Why: engine 側で `update_parallax` を呼んだ際に書き込み、`uniforms_with_viewport`
    ///      で transform.position に加算される。
    pub parallax_offset: [f32; 2],
}

impl Layer {
    /// RGBA8ピクセルデータからレイヤーを作成する
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        bind_group_layout: &wgpu::BindGroupLayout,
        sampler: &wgpu::Sampler,
        name: &str,
        width: u32,
        height: u32,
        rgba_data: &[u8],
    ) -> Self {
        let id = uuid::Uuid::new_v4().to_string();

        // RGBA→BGRA変換（パイプライン出力がBgra8Unormのため統一する）
        let bgra_data = rgba_to_bgra(rgba_data);

        // BGRA8テクスチャ作成（キャンバスと同じフォーマットに統一）
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(&format!("レイヤーテクスチャ: {}", name)),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Bgra8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        // ピクセルデータをアップロード
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &bgra_data,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(width * 4),
                rows_per_image: Some(height),
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );

        let texture_view = texture.create_view(&wgpu::TextureViewDescriptor::default());

        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(&format!("レイヤーバインドグループ: {}", name)),
            layout: bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&texture_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(sampler),
                },
            ],
        });

        log::info!("レイヤー作成: {} ({}x{}, ID: {})", name, width, height, id);

        Self {
            id,
            name: name.to_string(),
            texture,
            texture_view,
            bind_group,
            width,
            height,
            transform: LayerTransform::default(),
            opacity: 1.0,
            blend_mode: BlendMode::Normal,
            visible: true,
            animation_config: None,
            adjustments: ImageAdjustments::default(),
            editor_transform: None,
            flow_field: None,
            parallax: None,
            parallax_offset: [0.0, 0.0],
        }
    }

    /// アニメーション適用後のユニフォームデータを生成する（キャンバスモード用）
    #[allow(dead_code)]
    pub fn uniforms(&self, canvas_width: f32, canvas_height: f32, delta: &TransformDelta) -> LayerUniforms {
        self.uniforms_with_viewport(canvas_width, canvas_height, delta, None)
    }

    /// アニメーション適用後のユニフォームデータを生成する（ビューポート対応）
    /// viewport指定時: レイヤー→キャンバス→ビューポートの合成変換行列を計算する
    pub fn uniforms_with_viewport(
        &self,
        canvas_width: f32,
        canvas_height: f32,
        delta: &TransformDelta,
        viewport: Option<&ViewportParams>,
    ) -> LayerUniforms {
        let lw = self.width as f32;
        let lh = self.height as f32;

        // エディタ用変形が設定されている場合はそちらを優先
        // Phase 4B: parallax_offset を position に加算する。
        let layer_to_canvas = if let Some(et) = &self.editor_transform {
            let mut et = *et;
            et.offset_x += delta.position[0] + self.parallax_offset[0];
            et.offset_y += delta.position[1] + self.parallax_offset[1];
            et.scale_x *= delta.scale[0];
            et.scale_y *= delta.scale[1];
            et.rotation += delta.rotation;
            et.to_matrix(canvas_width, canvas_height, lw, lh)
        } else {
            let mut t = self.transform;
            t.position[0] += delta.position[0] + self.parallax_offset[0];
            t.position[1] += delta.position[1] + self.parallax_offset[1];
            t.scale[0] *= delta.scale[0];
            t.scale[1] *= delta.scale[1];
            t.rotation += delta.rotation;
            t.to_matrix(canvas_width, canvas_height, lw, lh)
        };

        // ビューポートモード時: キャンバスNDC → ビューポートNDCの変換を合成
        let forward_matrix = if let Some(vp) = viewport {
            let c2v = canvas_to_viewport_matrix(vp, canvas_width, canvas_height);
            mul_mat4(c2v, layer_to_canvas)
        } else {
            layer_to_canvas
        };

        // シェーダーではビューポート（orキャンバス）NDC→レイヤーNDCの逆変換が必要
        let transform_matrix = invert_mat4(forward_matrix);

        let opacity = (self.opacity * delta.opacity).clamp(0.0, 1.0);

        let adj = &self.adjustments;
        LayerUniforms {
            transform: transform_matrix,
            opacity,
            blend_mode: self.blend_mode as u32,
            canvas_size: [canvas_width, canvas_height],
            layer_size: [lw, lh],
            brightness: adj.brightness,
            contrast: adj.contrast,
            saturation: adj.saturation,
            temperature: adj.temperature,
            sharpness: adj.sharpness,
            gamma: adj.gamma,
            exposure: adj.exposure,
            filter_type: adj.filter_type,
            _padding: [0.0; 2],
        }
    }

    /// テクスチャを更新する（動画フレーム差し替え用）
    /// サイズが同じ場合は上書き、異なる場合は再作成
    pub fn update_texture(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        bind_group_layout: &wgpu::BindGroupLayout,
        sampler: &wgpu::Sampler,
        width: u32,
        height: u32,
        rgba_data: &[u8],
    ) {
        // RGBA→BGRA変換
        let bgra_data = rgba_to_bgra(rgba_data);

        if self.width == width && self.height == height {
            // サイズ同一：テクスチャ内容だけ上書き
            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &self.texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &bgra_data,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(width * 4),
                    rows_per_image: Some(height),
                },
                wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
            );
        } else {
            // サイズ変更：テクスチャを再作成
            let texture = device.create_texture(&wgpu::TextureDescriptor {
                label: Some(&format!("レイヤーテクスチャ: {}", self.name)),
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Bgra8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });

            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &bgra_data,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(width * 4),
                    rows_per_image: Some(height),
                },
                wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
            );

            let texture_view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some(&format!("レイヤーバインドグループ: {}", self.name)),
                layout: bind_group_layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(&texture_view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::Sampler(sampler),
                    },
                ],
            });

            self.texture = texture;
            self.texture_view = texture_view;
            self.bind_group = bind_group;
            self.width = width;
            self.height = height;
        }
    }
}

/// RGBA8バイト列をBGRA8に変換する（RとBチャンネルを入れ替え）
fn rgba_to_bgra(rgba: &[u8]) -> Vec<u8> {
    let mut bgra = rgba.to_vec();
    for chunk in bgra.chunks_exact_mut(4) {
        chunk.swap(0, 2); // R ↔ B
    }
    bgra
}
