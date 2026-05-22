// レイヤー合成パイプライン
// 複数レイヤーをping-pongバッファで順に合成する
// ビューポートモード時は背景（ワークスペース＋チェッカーボード）も描画する

use crate::layer::Layer;
use crate::motion::FlowFieldParams;
use crate::types::{LayerUniforms, MaskApplyUniforms, ViewportParams, ViewportUniforms};

/// レイヤー合成に必要なGPUリソース
pub struct Compositor {
    /// 合成パイプライン
    pub pipeline: wgpu::RenderPipeline,
    /// レイヤーテクスチャ用バインドグループレイアウト (group 0)
    pub layer_bind_group_layout: wgpu::BindGroupLayout,
    /// ユニフォーム用バインドグループレイアウト (group 1)
    pub uniform_bind_group_layout: wgpu::BindGroupLayout,
    /// キャンバステクスチャ用バインドグループレイアウト (group 2)
    pub canvas_bind_group_layout: wgpu::BindGroupLayout,
    /// ユニフォームバッファプール（フレーム間で再利用し、毎フレームの生成コストを回避）
    uniform_pool: Vec<(wgpu::Buffer, wgpu::BindGroup)>,
    /// Ping-pongテクスチャA
    pub canvas_a: wgpu::Texture,
    pub canvas_a_view: wgpu::TextureView,
    pub canvas_a_bind_group: wgpu::BindGroup,
    /// Ping-pongテクスチャB
    pub canvas_b: wgpu::Texture,
    pub canvas_b_view: wgpu::TextureView,
    pub canvas_b_bind_group: wgpu::BindGroup,
    /// サンプラー
    pub sampler: wgpu::Sampler,
    /// レンダリングサイズ
    pub width: u32,
    pub height: u32,

    // ビューポート背景パイプライン
    /// 背景描画パイプライン（ワークスペースグレー + チェッカーボード）
    background_pipeline: wgpu::RenderPipeline,
    /// ビューポートユニフォーム用バインドグループレイアウト
    #[allow(dead_code)]
    viewport_uniform_layout: wgpu::BindGroupLayout,
    /// ビューポートユニフォームバッファ
    viewport_uniform_buffer: wgpu::Buffer,
    /// ビューポートユニフォームバインドグループ
    viewport_uniform_bind_group: wgpu::BindGroup,

    /// キャンバス解像度（マスクテクスチャサイズ = プロジェクト解像度）
    pub mask_canvas_width: u32,
    pub mask_canvas_height: u32,
    /// R8 マスク（キャンバス座標）
    pub mask_texture: wgpu::Texture,
    pub mask_texture_view: wgpu::TextureView,
    mask_sampler: wgpu::Sampler,
    mask_bind_group_layout: wgpu::BindGroupLayout,
    mask_bind_group: wgpu::BindGroup,
    mask_uniform_buffer: wgpu::Buffer,
    mask_uniform_bind_group: wgpu::BindGroup,
    mask_apply_pipeline: wgpu::RenderPipeline,

    // フローフィールド用 (group 3)
    /// フローフィールドテクスチャ用バインドグループレイアウト
    pub flow_bind_group_layout: wgpu::BindGroupLayout,
    /// フローフィールド用サンプラー（線形補間）
    pub flow_sampler: wgpu::Sampler,
    /// FlowFieldParams 用ユニフォームバッファ（レイヤーごとに上書き）
    pub flow_uniform_buffer: wgpu::Buffer,
    /// フロー無効時に bind するダミーフィールド（1x1, 値=0）
    /// （bind_group が参照を保持しているのでテクスチャは保持しておく必要がある）
    #[allow(dead_code)]
    flow_dummy_texture: wgpu::Texture,
    /// フロー無効時用ダミーバインドグループ
    flow_dummy_bind_group: wgpu::BindGroup,
    /// FlowFieldParams 用バインドグループ（将来の汎用バッファ供給用）
    #[allow(dead_code)]
    pub flow_uniform_bind_group: wgpu::BindGroup,
}

impl Compositor {
    pub fn new(device: &wgpu::Device, width: u32, height: u32, canvas_width: u32, canvas_height: u32) -> Self {
        // サンプラー
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("合成サンプラー"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        // バインドグループレイアウト: レイヤーテクスチャ (group 0)
        let layer_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("レイヤーテクスチャレイアウト"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        // バインドグループレイアウト: ユニフォーム (group 1)
        let uniform_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("ユニフォームレイアウト"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        // バインドグループレイアウト: キャンバステクスチャ (group 2)
        let canvas_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("キャンバステクスチャレイアウト"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        // フローフィールド用 bind group layout (group 3)
        // binding 0: Rg16Float テクスチャ（速度ベクトル場）
        // binding 1: サンプラー
        // binding 2: FlowFieldParams ユニフォーム
        let flow_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("フローフィールドレイアウト"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });

        // フロー用サンプラー（線形補間でベクトル場を滑らかにサンプル）
        let flow_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("フローサンプラー"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        // FlowFieldParams ユニフォームバッファ
        let flow_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("FlowFieldParams"),
            size: std::mem::size_of::<FlowFieldParams>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // フロー無効時用ダミーテクスチャ（1x1 Rg16Float, 値ゼロ）
        let flow_dummy_texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("フローダミーテクスチャ"),
            size: wgpu::Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rg16Float,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let flow_dummy_view = flow_dummy_texture.create_view(&wgpu::TextureViewDescriptor::default());

        let flow_dummy_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("フローダミーBG"),
            layout: &flow_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&flow_dummy_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&flow_sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: flow_uniform_buffer.as_entire_binding(),
                },
            ],
        });

        // FlowFieldParams 単独バインドグループ（テクスチャ付きで使う場合は flow_field 側のbind_groupを使う）
        let flow_uniform_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("フローuniformBG"),
            layout: &flow_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&flow_dummy_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&flow_sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: flow_uniform_buffer.as_entire_binding(),
                },
            ],
        });

        // 合成シェーダーモジュール
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("合成シェーダー"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/composite.wgsl").into()),
        });

        // 合成パイプラインレイアウト（group 3 にフローフィールド追加）
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("合成パイプラインレイアウト"),
            bind_group_layouts: &[
                &layer_bind_group_layout,
                &uniform_bind_group_layout,
                &canvas_bind_group_layout,
                &flow_bind_group_layout,
            ],
            push_constant_ranges: &[],
        });

        // 合成レンダーパイプライン（出力はBgra8Unorm）
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("合成パイプライン"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        // ビューポート背景パイプライン
        let (background_pipeline, viewport_uniform_layout, viewport_uniform_buffer, viewport_uniform_bind_group) =
            Self::create_background_pipeline(device);

        // Ping-pongテクスチャ
        let (canvas_a, canvas_a_view, canvas_a_bind_group) =
            Self::create_canvas_texture(device, &canvas_bind_group_layout, &sampler, width, height, "キャンバスA");
        let (canvas_b, canvas_b_view, canvas_b_bind_group) =
            Self::create_canvas_texture(device, &canvas_bind_group_layout, &sampler, width, height, "キャンバスB");

        let cw = canvas_width.max(1);
        let ch = canvas_height.max(1);

        let mask_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("マスクサンプラー"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let mask_bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("マスクテクスチャレイアウト"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let mask_uniform_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("マスク適用ユニフォームレイアウト"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        let mask_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("マスク適用ユニフォーム"),
            size: std::mem::size_of::<MaskApplyUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let mask_uniform_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("マスク適用ユニフォームBG"),
            layout: &mask_uniform_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: mask_uniform_buffer.as_entire_binding(),
            }],
        });

        let (mask_texture, mask_texture_view, mask_bind_group) =
            Self::create_mask_texture(device, &mask_bind_group_layout, &mask_sampler, cw, ch);

        let mask_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("マスク適用シェーダー"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/mask_apply.wgsl").into()),
        });

        let mask_pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("マスク適用パイプラインレイアウト"),
            bind_group_layouts: &[
                &canvas_bind_group_layout,
                &mask_bind_group_layout,
                &mask_uniform_layout,
            ],
            push_constant_ranges: &[],
        });

        let mask_apply_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("マスク適用パイプライン"),
            layout: Some(&mask_pipeline_layout),
            vertex: wgpu::VertexState {
                module: &mask_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &mask_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        Self {
            pipeline,
            layer_bind_group_layout,
            uniform_bind_group_layout,
            canvas_bind_group_layout,
            uniform_pool: Vec::new(),
            canvas_a,
            canvas_a_view,
            canvas_a_bind_group,
            canvas_b,
            canvas_b_view,
            canvas_b_bind_group,
            sampler,
            width,
            height,
            background_pipeline,
            viewport_uniform_layout,
            viewport_uniform_buffer,
            viewport_uniform_bind_group,
            mask_canvas_width: cw,
            mask_canvas_height: ch,
            mask_texture,
            mask_texture_view,
            mask_sampler,
            mask_bind_group_layout,
            mask_bind_group,
            mask_uniform_buffer,
            mask_uniform_bind_group,
            mask_apply_pipeline,
            flow_bind_group_layout,
            flow_sampler,
            flow_uniform_buffer,
            flow_dummy_texture,
            flow_dummy_bind_group,
            flow_uniform_bind_group,
        }
    }

    fn create_mask_texture(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        sampler: &wgpu::Sampler,
        width: u32,
        height: u32,
    ) -> (wgpu::Texture, wgpu::TextureView, wgpu::BindGroup) {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("キャンバスマスク R8"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::R8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = texture.create_view(&Default::default());
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("マスクバインドグループ"),
            layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(sampler),
                },
            ],
        });
        (texture, view, bind_group)
    }

    /// 背景描画パイプラインを作成する
    fn create_background_pipeline(
        device: &wgpu::Device,
    ) -> (
        wgpu::RenderPipeline,
        wgpu::BindGroupLayout,
        wgpu::Buffer,
        wgpu::BindGroup,
    ) {
        // ビューポートユニフォーム用バインドグループレイアウト
        let viewport_uniform_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("ビューポートユニフォームレイアウト"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        // ビューポートユニフォームバッファ
        let viewport_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("ビューポートユニフォームバッファ"),
            size: std::mem::size_of::<ViewportUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // バインドグループ
        let viewport_uniform_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("ビューポートユニフォームBG"),
            layout: &viewport_uniform_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: viewport_uniform_buffer.as_entire_binding(),
            }],
        });

        // 背景シェーダー
        let bg_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("背景シェーダー"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/background.wgsl").into()),
        });

        // 背景パイプラインレイアウト
        let bg_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("背景パイプラインレイアウト"),
            bind_group_layouts: &[&viewport_uniform_layout],
            push_constant_ranges: &[],
        });

        // 背景レンダーパイプライン
        let background_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("背景パイプライン"),
            layout: Some(&bg_layout),
            vertex: wgpu::VertexState {
                module: &bg_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &bg_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Bgra8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        (
            background_pipeline,
            viewport_uniform_layout,
            viewport_uniform_buffer,
            viewport_uniform_bind_group,
        )
    }

    /// ping-pongテクスチャを作成するヘルパー
    fn create_canvas_texture(
        device: &wgpu::Device,
        canvas_bind_group_layout: &wgpu::BindGroupLayout,
        sampler: &wgpu::Sampler,
        width: u32,
        height: u32,
        label: &str,
    ) -> (wgpu::Texture, wgpu::TextureView, wgpu::BindGroup) {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Bgra8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = texture.create_view(&Default::default());
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some(&format!("{} バインドグループ", label)),
            layout: canvas_bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(sampler),
                },
            ],
        });
        (texture, view, bind_group)
    }

    /// レンダリングサイズを変更する（ping-pongテクスチャ再作成）
    pub fn resize(&mut self, device: &wgpu::Device, width: u32, height: u32) {
        if self.width == width && self.height == height {
            return;
        }
        log::info!("コンポジターリサイズ: {}x{} → {}x{}", self.width, self.height, width, height);

        let (canvas_a, canvas_a_view, canvas_a_bind_group) =
            Self::create_canvas_texture(device, &self.canvas_bind_group_layout, &self.sampler, width, height, "キャンバスA");
        let (canvas_b, canvas_b_view, canvas_b_bind_group) =
            Self::create_canvas_texture(device, &self.canvas_bind_group_layout, &self.sampler, width, height, "キャンバスB");

        self.canvas_a = canvas_a;
        self.canvas_a_view = canvas_a_view;
        self.canvas_a_bind_group = canvas_a_bind_group;
        self.canvas_b = canvas_b;
        self.canvas_b_view = canvas_b_view;
        self.canvas_b_bind_group = canvas_b_bind_group;
        self.width = width;
        self.height = height;
    }

    /// プールにユニフォームバッファ/バインドグループを1エントリ追加する
    fn grow_pool(&mut self, device: &wgpu::Device) {
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("プールユニフォームバッファ"),
            size: std::mem::size_of::<LayerUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("プールユニフォームBG"),
            layout: &self.uniform_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: buffer.as_entire_binding(),
            }],
        });
        self.uniform_pool.push((buffer, bind_group));
    }

    /// 全レイヤーを合成し、最終結果のテクスチャを返す（従来のキャンバスモード）
    pub fn composite(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        layers: &[Layer],
        elapsed_time: f32,
    ) -> &wgpu::Texture {
        self.composite_inner(device, queue, encoder, layers, elapsed_time, None)
    }

    /// 全レイヤーを合成し、最終結果のテクスチャを返す（ビューポートモード）
    /// viewport指定時: 背景描画 → レイヤー合成（ビューポート変換適用）
    pub fn composite_with_viewport(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        layers: &[Layer],
        elapsed_time: f32,
        canvas_width: f32,
        canvas_height: f32,
        viewport: &ViewportParams,
    ) -> &wgpu::Texture {
        self.composite_inner(
            device,
            queue,
            encoder,
            layers,
            elapsed_time,
            Some((canvas_width, canvas_height, viewport)),
        )
    }

    /// 合成の内部実装（ビューポートモード対応）
    fn composite_inner(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        layers: &[Layer],
        elapsed_time: f32,
        viewport: Option<(f32, f32, &ViewportParams)>,
    ) -> &wgpu::Texture {
        // ビューポートモード時: 背景（ワークスペース + チェッカーボード）を描画
        if let Some((canvas_w, canvas_h, vp)) = viewport {
            let vp_uniforms = ViewportUniforms {
                viewport_size: [vp.viewport_width, vp.viewport_height],
                canvas_size: [canvas_w, canvas_h],
                canvas_origin: [vp.canvas_origin_x, vp.canvas_origin_y],
                canvas_display_size: [canvas_w * vp.zoom, canvas_h * vp.zoom],
                checker_tile_size: 12.0,
                _padding: [0.0; 3],
            };
            queue.write_buffer(
                &self.viewport_uniform_buffer,
                0,
                bytemuck::bytes_of(&vp_uniforms),
            );

            // キャンバスAに背景を描画
            {
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("背景描画"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &self.canvas_a_view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color {
                                r: 0.2,
                                g: 0.2,
                                b: 0.2,
                                a: 1.0,
                            }),
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    depth_stencil_attachment: None,
                    ..Default::default()
                });
                pass.set_pipeline(&self.background_pipeline);
                pass.set_bind_group(0, &self.viewport_uniform_bind_group, &[]);
                pass.draw(0..3, 0..1);
            }
        } else {
            // キャンバスモード: 透明色でクリア
            {
                let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("キャンバスクリア"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &self.canvas_a_view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    depth_stencil_attachment: None,
                    ..Default::default()
                });
            }
        }

        // 可視レイヤーがなければキャンバスAを返す
        let visible_layers: Vec<_> = layers.iter().filter(|l| l.visible).collect();
        if visible_layers.is_empty() {
            return &self.canvas_a;
        }

        // ビューポートモード時のキャンバスサイズ（レイヤー変形用）と合成サイズを分離
        let (canvas_w_for_transform, canvas_h_for_transform) = match viewport {
            Some((cw, ch, _)) => (cw, ch),
            None => (self.width as f32, self.height as f32),
        };

        // プールサイズが足りなければ追加分だけ拡張
        while self.uniform_pool.len() < visible_layers.len() {
            self.grow_pool(device);
        }

        // RenderPass開始前に全レイヤーのユニフォームデータをプールバッファに書き込む
        for (i, layer) in visible_layers.iter().enumerate() {
            let delta = layer
                .animation_config
                .as_ref()
                .map(|c| c.evaluate(elapsed_time))
                .unwrap_or_default();

            let uniforms = layer.uniforms_with_viewport(
                canvas_w_for_transform,
                canvas_h_for_transform,
                &delta,
                viewport.map(|(_, _, vp)| vp),
            );
            let uniform_bytes = bytemuck::bytes_of(&uniforms);
            queue.write_buffer(&self.uniform_pool[i].0, 0, uniform_bytes);
        }

        // ping-pong: 偶数回目はA→B、奇数回目はB→A
        for (i, layer) in visible_layers.iter().enumerate() {
            let (src_bind_group, dst_view) = if i % 2 == 0 {
                (&self.canvas_a_bind_group, &self.canvas_b_view)
            } else {
                (&self.canvas_b_bind_group, &self.canvas_a_view)
            };

            // フローフィールド bind group: 有効なFlowFieldがあればそれを、無ければダミーを使用
            // どちらの場合も FlowFieldParams を「現在のレイヤー用パラメータ」へ書き込む
            // （uniform_bufferはCompositor全体で共有し、レイヤーごとに上書きする）
            let flow_bg: &wgpu::BindGroup = match layer.flow_field.as_ref() {
                Some(ff) if ff.params.enabled != 0 => {
                    queue.write_buffer(
                        &self.flow_uniform_buffer,
                        0,
                        bytemuck::bytes_of(&ff.params),
                    );
                    &ff.bind_group
                }
                _ => {
                    let disabled = FlowFieldParams::default();
                    queue.write_buffer(
                        &self.flow_uniform_buffer,
                        0,
                        bytemuck::bytes_of(&disabled),
                    );
                    &self.flow_dummy_bind_group
                }
            };

            {
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some(&format!("レイヤー合成 #{}", i)),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: dst_view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    depth_stencil_attachment: None,
                    ..Default::default()
                });

                pass.set_pipeline(&self.pipeline);
                pass.set_bind_group(0, &layer.bind_group, &[]);
                pass.set_bind_group(1, &self.uniform_pool[i].1, &[]);
                pass.set_bind_group(2, src_bind_group, &[]);
                pass.set_bind_group(3, flow_bg, &[]);
                pass.draw(0..3, 0..1);
            }
        }

        // 最終結果が入っているテクスチャを返す
        let layer_count = visible_layers.len();
        if layer_count % 2 == 0 {
            &self.canvas_a
        } else {
            &self.canvas_b
        }
    }

    /// キャンバス解像度のマスクテクスチャをリサイズする（プロジェクト解像度変更時）
    pub fn resize_mask_canvas(&mut self, device: &wgpu::Device, canvas_w: u32, canvas_h: u32) {
        let w = canvas_w.max(1);
        let h = canvas_h.max(1);
        if self.mask_canvas_width == w && self.mask_canvas_height == h {
            return;
        }
        log::info!(
            "マスクテクスチャリサイズ: {}x{} → {}x{}",
            self.mask_canvas_width,
            self.mask_canvas_height,
            w,
            h
        );
        self.mask_canvas_width = w;
        self.mask_canvas_height = h;
        let (tex, view, bg) =
            Self::create_mask_texture(device, &self.mask_bind_group_layout, &self.mask_sampler, w, h);
        self.mask_texture = tex;
        self.mask_texture_view = view;
        self.mask_bind_group = bg;
    }

    /// 合成結果にキャンバスマスク（R8）を乗算する。apply_mask が false のときは合成結果をそのままにする。
    /// 戻り値: 最終ピクセルが canvas_a にあるか（true = A, false = B）
    pub fn apply_canvas_mask_if_needed(
        &mut self,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        composite_in_canvas_a: bool,
        apply_mask: bool,
        has_viewport_transform: bool,
        viewport: Option<&ViewportParams>,
        canvas_w: f32,
        canvas_h: f32,
    ) -> bool {
        if !apply_mask {
            return composite_in_canvas_a;
        }

        let vp_w = self.width as f32;
        let vp_h = self.height as f32;
        let uniforms = if has_viewport_transform {
            let vp = viewport.expect("viewport params required when has_viewport_transform");
            MaskApplyUniforms {
                viewport_size: [vp_w, vp_h],
                canvas_size: [canvas_w, canvas_h],
                canvas_origin: [vp.canvas_origin_x, vp.canvas_origin_y],
                zoom: vp.zoom,
                viewport_mode: 1.0,
                _padding: [0.0; 2],
            }
        } else {
            MaskApplyUniforms {
                viewport_size: [vp_w, vp_h],
                canvas_size: [canvas_w, canvas_h],
                canvas_origin: [0.0, 0.0],
                zoom: 1.0,
                viewport_mode: 0.0,
                _padding: [0.0; 2],
            }
        };
        queue.write_buffer(&self.mask_uniform_buffer, 0, bytemuck::bytes_of(&uniforms));

        let (src_bind_group, dst_view) = if composite_in_canvas_a {
            (&self.canvas_a_bind_group, &self.canvas_b_view)
        } else {
            (&self.canvas_b_bind_group, &self.canvas_a_view)
        };

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("マスク適用"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: dst_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                ..Default::default()
            });
            pass.set_pipeline(&self.mask_apply_pipeline);
            pass.set_bind_group(0, src_bind_group, &[]);
            pass.set_bind_group(1, &self.mask_bind_group, &[]);
            pass.set_bind_group(2, &self.mask_uniform_bind_group, &[]);
            pass.draw(0..3, 0..1);
        }

        !composite_in_canvas_a
    }
}
