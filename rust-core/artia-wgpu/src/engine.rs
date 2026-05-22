// WGPUアニメーションエンジン本体
// ヘッドレスGPUレンダラーでレイヤーを合成し、IOSurfaceに出力する
// ビューポートモード: エディタウィンドウ全体をレンダリング（背景+チェッカーボード+レイヤー）
// キャンバスモード: プロジェクト解像度でレンダリング（エクスポート用）

use std::collections::{HashMap, HashSet};
use std::sync::mpsc;
use std::time::Duration;

use crate::animation::AnimationConfig;
use crate::compositor::Compositor;
use crate::iosurface::IOSurfaceHandle;
use crate::layer::Layer;
use crate::types::{BlendMode, EditorTransform, ImageAdjustments, LayerTransform, ViewportParams};

/// render_frame の戻り値
/// 0 = 成功, -1 = レンダリングエラー（GPU操作失敗）
pub type RenderStatus = i32;
pub const RENDER_OK: RenderStatus = 0;
pub const RENDER_ERROR: RenderStatus = -1;

/// WGPUアニメーションエンジン
pub struct WgpuEngine {
    device: wgpu::Device,
    queue: wgpu::Queue,

    /// プロジェクトのキャンバスサイズ（エクスポート解像度）
    canvas_width: u32,
    canvas_height: u32,

    /// キャンバスモード用IOSurface（常にcanvas_sizeで保持）
    iosurface: IOSurfaceHandle,
    /// キャンバスモード用ステージングバッファ
    staging_buffers: [wgpu::Buffer; 2],
    staging_index: usize,
    padded_bytes_per_row: u32,

    // ビューポートモード用リソース
    /// ビューポートサイズ（エディタ中央パネルのピクセル数）
    viewport_width: u32,
    viewport_height: u32,
    /// ビューポートパラメータ（ズーム・パン・キャンバス位置）
    viewport_params: Option<ViewportParams>,
    /// ビューポート用IOSurface
    viewport_iosurface: Option<IOSurfaceHandle>,
    /// ビューポート用ステージングバッファ
    viewport_staging_buffers: Option<[wgpu::Buffer; 2]>,
    viewport_staging_index: usize,
    viewport_padded_bytes_per_row: u32,
    /// ビューポートモードフラグ
    viewport_mode: bool,
    /// ビューポート: 前フレームのマップ完了通知（ダブルバッファリング用）
    viewport_pending_map: Option<(usize, mpsc::Receiver<Result<(), wgpu::BufferAsyncError>>)>,
    /// キャンバス: 前フレームのマップ完了通知（ダブルバッファリング用）
    canvas_pending_map: Option<(usize, mpsc::Receiver<Result<(), wgpu::BufferAsyncError>>)>,

    /// レイヤー合成パイプライン
    compositor: Compositor,

    /// レイヤー一覧（描画順序: index 0 = 最背面）
    layers: Vec<Layer>,
    /// レイヤーID → インデックスマッピング
    layer_index: HashMap<String, usize>,

    /// マスクバッファ（R8フォーマット、0-255）
    mask_width: u32,
    mask_height: u32,
    mask_pixels: Vec<u8>,
    /// GPU マスクテクスチャへ未反映の変更がある
    mask_gpu_dirty: bool,

    /// 経過時間
    elapsed_time: f32,
    /// 再生中フラグ
    is_playing: bool,

    /// パーティクルシステム一覧 (Phase 4A)
    /// Why: ParticleSystem を CPU 側で simulate しつつ、後続フェーズで GPU compute / render を
    ///      この同じ Vec から dispatch できるようにエンジン本体に保持する。
    particle_systems: Vec<crate::particle::ParticleSystem>,
    /// 次に発行する ParticleSystemId カウンタ。
    next_particle_id: u32,

    /// Light レイヤー一覧 (Phase 4B)
    /// Why: descriptor を保持し、後続フェーズで compositor の light pass に流す。
    light_layers: Vec<crate::light::LightLayer>,
    /// 次に発行する LightLayerId カウンタ。
    next_light_id: u32,

    /// パララックス: 現在のマウスオフセット (-1.0 .. 1.0)。
    /// Why: 各フレーム冒頭で全レイヤーの parallax_offset に展開する。
    parallax_mouse: [f32; 2],

    /// PuppetWarp 一覧 (Phase 4C)
    /// Why: メッシュと制御点を保持し、毎フレーム / 更新時に CPU で頂点位置を計算する。
    puppet_warps: Vec<crate::warp::PuppetWarp>,
    next_puppet_warp_id: u32,

    /// Skeleton 一覧 (Phase 4C)
    /// Why: ボーン階層と LBS スキニング結果を保持する。後続フェーズで GPU 経路へ流す。
    skeletons: Vec<crate::bone::Skeleton>,
    next_skeleton_id: u32,

    /// Audio Reactive uniform (Phase 6A)
    /// Why: Swift 側で計算した FFT バンドを保持し、particle simulate で emit rate 変調や
    ///      シェーダ側で参照するためのソースとなる。
    audio_uniform: crate::audio::AudioUniform,

    /// Spanning Canvas (Phase 7B)
    /// Why: 複数ディスプレイをまたぐ 1 枚キャンバスのレイアウトをエンジン側に保持し、
    ///      後続フェーズで各 IOSurface への切り出し描画に使う。
    spanning_canvas: Option<crate::spanning::SpanningCanvas>,
}

impl WgpuEngine {
    /// エンジンを作成する
    pub fn new(canvas_width: u32, canvas_height: u32) -> Result<Self, String> {
        log::info!(
            "WGPUエンジン初期化開始 ({}x{})",
            canvas_width,
            canvas_height
        );

        // wgpuインスタンス（macOSではMetalバックエンド）
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            ..Default::default()
        });

        // アダプター取得（ヘッドレス：サーフェスなし）
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .ok_or_else(|| "GPUアダプター取得失敗".to_string())?;

        log::info!("GPUアダプター: {:?}", adapter.get_info().name);

        // デバイス・キュー取得
        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("Artia WGPUデバイス"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::Performance,
            },
            None,
        ))
        .map_err(|e| format!("GPUデバイス取得失敗: {}", e))?;

        // バリデーションエラーでパニックしないようエラーハンドラを設定
        device.on_uncaptured_error(Box::new(|error| {
            log::error!("wgpuデバイスエラー: {}", error);
        }));

        // キャンバスモード用ステージングバッファ
        let padded_bytes_per_row = (canvas_width * 4 + 255) & !255;
        let buffer_size = (padded_bytes_per_row as u64) * (canvas_height as u64);
        let create_staging = |label: &str| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: buffer_size,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            })
        };
        let staging_buffers = [
            create_staging("ステージングバッファA"),
            create_staging("ステージングバッファB"),
        ];

        // キャンバスモード用IOSurface
        let iosurface = IOSurfaceHandle::new(canvas_width, canvas_height)?;

        // コンポジター（初期サイズ = キャンバスサイズ、マスクはキャンバス解像度）
        let compositor = Compositor::new(&device, canvas_width, canvas_height, canvas_width, canvas_height);

        log::info!("WGPUエンジン初期化完了");

        Ok(Self {
            device,
            queue,
            canvas_width,
            canvas_height,
            iosurface,
            staging_buffers,
            staging_index: 0,
            padded_bytes_per_row,
            viewport_width: 0,
            viewport_height: 0,
            viewport_params: None,
            viewport_iosurface: None,
            viewport_staging_buffers: None,
            viewport_staging_index: 0,
            viewport_padded_bytes_per_row: 0,
            viewport_mode: false,
            viewport_pending_map: None,
            canvas_pending_map: None,
            compositor,
            layers: Vec::new(),
            layer_index: HashMap::new(),
            mask_width: canvas_width,
            mask_height: canvas_height,
            // 白 = マスク無効（合成をそのまま表示）
            mask_pixels: vec![255; (canvas_width as usize) * (canvas_height as usize)],
            mask_gpu_dirty: true,
            elapsed_time: 0.0,
            is_playing: true,
            particle_systems: Vec::new(),
            next_particle_id: 1,
            light_layers: Vec::new(),
            next_light_id: 1,
            parallax_mouse: [0.0, 0.0],
            puppet_warps: Vec::new(),
            next_puppet_warp_id: 1,
            skeletons: Vec::new(),
            next_skeleton_id: 1,
            audio_uniform: crate::audio::AudioUniform::default(),
            spanning_canvas: None,
        })
    }

    // MARK: - Spanning canvas (Phase 7B)

    /// スパニングキャンバスを差し替える。`None` を渡すとクリア。
    pub fn set_spanning_canvas(
        &mut self,
        canvas: Option<crate::spanning::SpanningCanvas>,
    ) -> Result<(), crate::spanning::SpanningError> {
        if let Some(ref c) = canvas {
            c.validate()?;
        }
        self.spanning_canvas = canvas;
        Ok(())
    }

    /// 現在のスパニングキャンバスを参照
    pub fn spanning_canvas(&self) -> Option<&crate::spanning::SpanningCanvas> {
        self.spanning_canvas.as_ref()
    }

    /// キャンバスモード用IOSurfaceの生ポインタを返す
    pub fn iosurface_ptr(&self) -> *mut std::ffi::c_void {
        self.iosurface.as_ptr()
    }

    /// 現在アクティブなIOSurfaceの生ポインタを返す（ビューポートモード対応）
    pub fn active_iosurface_ptr(&self) -> *mut std::ffi::c_void {
        if self.viewport_mode {
            if let Some(ref vp_ios) = self.viewport_iosurface {
                return vp_ios.as_ptr();
            }
        }
        self.iosurface.as_ptr()
    }

    // =========================================================================
    // ビューポート管理
    // =========================================================================

    /// ビューポートサイズを設定する（IOSurface・ステージングバッファ再作成）
    /// 戻り値: 新しいIOSurfaceの生ポインタ
    pub fn set_viewport_size(&mut self, width: u32, height: u32) -> *mut std::ffi::c_void {
        let w = width.max(1);
        let h = height.max(1);

        // サイズが同じなら再作成不要
        if self.viewport_width == w && self.viewport_height == h {
            if let Some(ref ios) = self.viewport_iosurface {
                return ios.as_ptr();
            }
        }

        #[cfg(debug_assertions)]
        log::info!("ビューポートサイズ設定: {}x{}", w, h);

        self.viewport_width = w;
        self.viewport_height = h;

        // IOSurface再作成
        match IOSurfaceHandle::new(w, h) {
            Ok(ios) => {
                let ptr = ios.as_ptr();
                self.viewport_iosurface = Some(ios);

                // ステージングバッファ再作成
                let padded_bpr = (w * 4 + 255) & !255;
                let buf_size = (padded_bpr as u64) * (h as u64);
                let create_buf = |label: &str| {
                    self.device.create_buffer(&wgpu::BufferDescriptor {
                        label: Some(label),
                        size: buf_size,
                        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                        mapped_at_creation: false,
                    })
                };
                self.viewport_staging_buffers = Some([
                    create_buf("VPステージングA"),
                    create_buf("VPステージングB"),
                ]);
                self.viewport_staging_index = 0;
                self.viewport_padded_bytes_per_row = padded_bpr;
                // サイズ変更時は古いバッファの pending を破棄
                self.viewport_pending_map = None;

                // コンポジターをビューポートサイズにリサイズ
                if self.viewport_mode {
                    self.compositor.resize(&self.device, w, h);
                }

                ptr
            }
            Err(e) => {
                log::error!("ビューポートIOSurface作成失敗: {}", e);
                std::ptr::null_mut()
            }
        }
    }

    /// ビューポートパラメータを更新する（ズーム・パン変更時）
    pub fn set_viewport_params(
        &mut self,
        zoom: f32,
        pan_x: f32,
        pan_y: f32,
        canvas_origin_x: f32,
        canvas_origin_y: f32,
    ) {
        self.viewport_params = Some(ViewportParams {
            viewport_width: self.viewport_width as f32,
            viewport_height: self.viewport_height as f32,
            zoom,
            pan_x,
            pan_y,
            canvas_origin_x,
            canvas_origin_y,
        });
    }

    /// ビューポートモードの有効/無効を切り替える
    pub fn set_viewport_mode(&mut self, enabled: bool) {
        if self.viewport_mode == enabled {
            return;
        }
        self.viewport_mode = enabled;

        if enabled && self.viewport_width > 0 && self.viewport_height > 0 {
            // ビューポートサイズにリサイズ
            self.compositor
                .resize(&self.device, self.viewport_width, self.viewport_height);
        } else if !enabled {
            // キャンバスサイズに戻す
            self.compositor
                .resize(&self.device, self.canvas_width, self.canvas_height);
        }
    }

    // =========================================================================
    // レンダリング
    // =========================================================================

    /// 1フレームをレンダリングし、IOSurfaceに即座に出力する
    /// 戻り値: 0 = 成功, -1 = レンダリングエラー
    pub fn render_frame(&mut self, delta_time: f32) -> RenderStatus {
        if self.is_playing {
            self.elapsed_time += delta_time;
        }

        // 水流ブラシ用: 全レイヤーの FlowFieldParams.time を現在の経過時間で更新
        for layer in &mut self.layers {
            if let Some(ff) = layer.flow_field.as_mut() {
                ff.params.time = self.elapsed_time;
            }
        }

        // Phase 4A: 全 ParticleSystem を CPU シミュレーションで進める。
        // Why: GPU compute kernel 経路は後続フェーズで dispatch を有効化する。
        //      `is_playing == false` のときは時間進行を抑止する。
        // Phase 6A: audio_binding がある emitter は audio uniform で spawn rate を変調する。
        if self.is_playing {
            let audio = self.audio_uniform.clone();
            for system in &mut self.particle_systems {
                system.simulate_cpu_with_audio(delta_time, &audio);
            }
        }

        // Phase 4B: パララックスオフセットを各レイヤーへ反映する。
        // Why: マウス位置に応じた px オフセットを `parallax_offset` に書き込めば、
        //      `Layer::uniforms_with_viewport` が transform.position に加算する。
        for layer in &mut self.layers {
            if let Some(setting) = &layer.parallax {
                layer.parallax_offset = setting.compute_offset(self.parallax_mouse);
            } else {
                layer.parallax_offset = [0.0, 0.0];
            }
        }

        // ビューポートモードとキャンバスモードでレンダリングパスを分岐
        if self.viewport_mode {
            self.render_viewport_frame()
        } else {
            self.render_canvas_frame()
        }
    }

    /// ビューポートモードでレンダリング（エディタウィンドウ全体）
    fn render_viewport_frame(&mut self) -> RenderStatus {
        let vp_w = self.viewport_width;
        let vp_h = self.viewport_height;

        if vp_w == 0 || vp_h == 0 {
            log::warn!("ビューポートレンダリングスキップ: サイズ={}x{}", vp_w, vp_h);
            return RENDER_OK;
        }

        if self.compositor.width != vp_w || self.compositor.height != vp_h {
            #[cfg(debug_assertions)]
            log::info!(
                "コンポジターサイズ不一致を修正: {}x{} → {}x{}",
                self.compositor.width,
                self.compositor.height,
                vp_w,
                vp_h
            );
            self.compositor.resize(&self.device, vp_w, vp_h);
        }

        if self.mask_gpu_dirty {
            self.upload_mask_gpu();
            self.mask_gpu_dirty = false;
        }

        let vp_staging = match self.viewport_staging_buffers {
            Some(ref buffers) => buffers,
            None => return RENDER_OK,
        };
        let vp_ios = match self.viewport_iosurface {
            Some(ref ios) => ios,
            None => return RENDER_OK,
        };

        let vp_padded_bpr = self.viewport_padded_bytes_per_row;
        let vp_bytes_per_row = vp_w * 4;
        let buf_idx = self.viewport_staging_index;

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("ビューポートフレームエンコーダー"),
            });

        let canvas_w = self.canvas_width as f32;
        let canvas_h = self.canvas_height as f32;
        let vp = self.viewport_params.unwrap_or(ViewportParams {
            viewport_width: vp_w as f32,
            viewport_height: vp_h as f32,
            zoom: 1.0,
            pan_x: 0.0,
            pan_y: 0.0,
            canvas_origin_x: 0.0,
            canvas_origin_y: 0.0,
        });

        #[cfg(debug_assertions)]
        {
            static FRAME_COUNT: std::sync::atomic::AtomicU32 =
                std::sync::atomic::AtomicU32::new(0);
            let frame = FRAME_COUNT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if frame < 5 || frame % 300 == 0 {
                log::debug!(
                    "ビューポートレンダリング #{}: vp={}x{}, canvas={}x{}, zoom={:.3}, origin=({:.1},{:.1}), layers={}, compositor={}x{}",
                    frame,
                    vp_w,
                    vp_h,
                    canvas_w,
                    canvas_h,
                    vp.zoom,
                    vp.canvas_origin_x,
                    vp.canvas_origin_y,
                    self.layers.len(),
                    self.compositor.width,
                    self.compositor.height
                );
            }
        }

        self.compositor.composite_with_viewport(
            &self.device,
            &self.queue,
            &mut encoder,
            &self.layers,
            self.elapsed_time,
            canvas_w,
            canvas_h,
            &vp,
        );

        let visible_count = self.layers.iter().filter(|l| l.visible).count();
        let composite_in_a = visible_count == 0 || visible_count % 2 == 0;
        let final_in_a = self.compositor.apply_canvas_mask_if_needed(
            &self.queue,
            &mut encoder,
            composite_in_a,
            !self.mask_identity(),
            true,
            self.viewport_params.as_ref(),
            canvas_w,
            canvas_h,
        );

        let result_texture = if final_in_a {
            &self.compositor.canvas_a
        } else {
            &self.compositor.canvas_b
        };

        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: result_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &vp_staging[buf_idx],
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(vp_padded_bpr),
                    rows_per_image: Some(vp_h),
                },
            },
            wgpu::Extent3d {
                width: vp_w,
                height: vp_h,
                depth_or_array_layers: 1,
            },
        );

        // フレームNをサブミット
        self.queue.submit(std::iter::once(encoder.finish()));

        // フレームN のバッファにマップ要求を出す（非同期 — 完了は次フレームで回収）
        let (tx, rx) = mpsc::channel::<Result<(), wgpu::BufferAsyncError>>();
        {
            let slice = vp_staging[buf_idx].slice(..);
            slice.map_async(wgpu::MapMode::Read, move |r| { let _ = tx.send(r); });
        }

        // 前フレーム(N-1) のマップ完了を回収してIOSurfaceに書く
        let status = if let Some((prev_idx, prev_rx)) = self.viewport_pending_map.take() {
            // GPUポール（非同期完了を拾う; ブロックしない）
            self.device.poll(wgpu::Maintain::Poll);
            let map_result = prev_rx.recv_timeout(Duration::from_millis(32));
            let s = if let Some(ref buffers) = self.viewport_staging_buffers {
                match map_result {
                    Ok(Ok(())) => {
                        let slice = buffers[prev_idx].slice(..);
                        let data = slice.get_mapped_range();
                        Self::copy_to_iosurface_static(vp_ios, &data, vp_bytes_per_row, vp_padded_bpr, vp_h);
                        drop(data);
                        buffers[prev_idx].unmap();
                        RENDER_OK
                    }
                    Ok(Err(e)) => {
                        log::error!("ビューポートステージングバッファマップ失敗: {:?}", e);
                        buffers[prev_idx].unmap();
                        RENDER_ERROR
                    }
                    Err(_) => {
                        // タイムアウト: 前フレームをスキップして継続（フレームドロップ扱い）
                        buffers[prev_idx].unmap();
                        RENDER_OK
                    }
                }
            } else {
                RENDER_OK
            };
            s
        } else {
            // 初回フレームは前フレームなし → GPUを同期待ちして確実にマップ
            self.device.poll(wgpu::Maintain::Wait);
            let map_result = rx.recv_timeout(Duration::from_secs(5));
            let s = if let Some(ref buffers) = self.viewport_staging_buffers {
                match map_result {
                    Ok(Ok(())) => {
                        let slice = buffers[buf_idx].slice(..);
                        let data = slice.get_mapped_range();
                        Self::copy_to_iosurface_static(vp_ios, &data, vp_bytes_per_row, vp_padded_bpr, vp_h);
                        drop(data);
                        buffers[buf_idx].unmap();
                        RENDER_OK
                    }
                    Ok(Err(e)) => {
                        log::error!("ビューポートステージングバッファマップ失敗(初回): {:?}", e);
                        buffers[buf_idx].unmap();
                        RENDER_ERROR
                    }
                    Err(_) => {
                        log::error!("ビューポートGPU応答タイムアウト(初回)");
                        RENDER_ERROR
                    }
                }
            } else {
                RENDER_OK
            };
            self.viewport_staging_index = 1 - self.viewport_staging_index;
            return s;
        };

        // フレームN の pending を保存して次フレームで回収
        self.viewport_pending_map = Some((buf_idx, rx));
        self.viewport_staging_index = 1 - self.viewport_staging_index;
        status
    }

    /// キャンバスモードでレンダリング（従来方式）
    fn render_canvas_frame(&mut self) -> RenderStatus {
        let bytes_per_row = self.canvas_width * 4;
        let padded_bytes_per_row = self.padded_bytes_per_row;

        if self.mask_gpu_dirty {
            self.upload_mask_gpu();
            self.mask_gpu_dirty = false;
        }

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("フレームエンコーダー"),
            });

        self.compositor.composite(
            &self.device,
            &self.queue,
            &mut encoder,
            &self.layers,
            self.elapsed_time,
        );

        let visible_count = self.layers.iter().filter(|l| l.visible).count();
        let composite_in_a = visible_count == 0 || visible_count % 2 == 0;
        let cw = self.canvas_width as f32;
        let ch = self.canvas_height as f32;
        let final_in_a = self.compositor.apply_canvas_mask_if_needed(
            &self.queue,
            &mut encoder,
            composite_in_a,
            !self.mask_identity(),
            false,
            None,
            cw,
            ch,
        );

        let result_texture = if final_in_a {
            &self.compositor.canvas_a
        } else {
            &self.compositor.canvas_b
        };

        let buf_idx = self.staging_index;
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: result_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &self.staging_buffers[buf_idx],
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_bytes_per_row),
                    rows_per_image: Some(self.canvas_height),
                },
            },
            wgpu::Extent3d {
                width: self.canvas_width,
                height: self.canvas_height,
                depth_or_array_layers: 1,
            },
        );

        // フレームNをサブミット
        self.queue.submit(std::iter::once(encoder.finish()));

        // フレームN のバッファにマップ要求を出す（非同期）
        let (tx, rx) = mpsc::channel::<Result<(), wgpu::BufferAsyncError>>();
        {
            let slice = self.staging_buffers[buf_idx].slice(..);
            slice.map_async(wgpu::MapMode::Read, move |r| { let _ = tx.send(r); });
        }

        // 前フレーム(N-1) のマップ完了を回収してIOSurfaceに書く
        let status = if let Some((prev_idx, prev_rx)) = self.canvas_pending_map.take() {
            self.device.poll(wgpu::Maintain::Poll);
            let map_result = prev_rx.recv_timeout(Duration::from_millis(32));
            let s = match map_result {
                Ok(Ok(())) => {
                    let slice = self.staging_buffers[prev_idx].slice(..);
                    let data = slice.get_mapped_range();
                    Self::copy_to_iosurface_static(
                        &self.iosurface, &data, bytes_per_row, padded_bytes_per_row, self.canvas_height,
                    );
                    drop(data);
                    self.staging_buffers[prev_idx].unmap();
                    RENDER_OK
                }
                Ok(Err(e)) => {
                    log::error!("キャンバスステージングバッファマップ失敗: {:?}", e);
                    self.staging_buffers[prev_idx].unmap();
                    RENDER_ERROR
                }
                Err(_) => {
                    self.staging_buffers[prev_idx].unmap();
                    RENDER_OK
                }
            };
            s
        } else {
            // 初回フレームは同期待ち
            self.device.poll(wgpu::Maintain::Wait);
            let map_result = rx.recv_timeout(Duration::from_secs(5));
            let s = match map_result {
                Ok(Ok(())) => {
                    let slice = self.staging_buffers[buf_idx].slice(..);
                    let data = slice.get_mapped_range();
                    Self::copy_to_iosurface_static(
                        &self.iosurface, &data, bytes_per_row, padded_bytes_per_row, self.canvas_height,
                    );
                    drop(data);
                    self.staging_buffers[buf_idx].unmap();
                    RENDER_OK
                }
                Ok(Err(e)) => {
                    log::error!("キャンバスステージングバッファマップ失敗(初回): {:?}", e);
                    self.staging_buffers[buf_idx].unmap();
                    RENDER_ERROR
                }
                Err(_) => {
                    log::error!("キャンバスGPU応答タイムアウト(初回)");
                    RENDER_ERROR
                }
            };
            self.staging_index = 1 - self.staging_index;
            return s;
        };

        self.canvas_pending_map = Some((buf_idx, rx));
        self.staging_index = 1 - self.staging_index;
        status
    }

    /// ステージングバッファのデータをIOSurfaceにコピーする（staticメソッド）
    fn copy_to_iosurface_static(
        iosurface: &IOSurfaceHandle,
        data: &[u8],
        bytes_per_row: u32,
        padded_bytes_per_row: u32,
        height: u32,
    ) {
        if padded_bytes_per_row == bytes_per_row {
            iosurface.write_pixels(data);
        } else {
            let mut unpadded = Vec::with_capacity((bytes_per_row * height) as usize);
            for row in 0..height as usize {
                let start = row * padded_bytes_per_row as usize;
                let end = start + bytes_per_row as usize;
                unpadded.extend_from_slice(&data[start..end]);
            }
            iosurface.write_pixels(&unpadded);
        }
    }

    /// 経過時間をリセットする
    pub fn reset_time(&mut self) {
        self.elapsed_time = 0.0;
    }

    /// 再生/一時停止を設定する
    pub fn set_playing(&mut self, playing: bool) {
        self.is_playing = playing;
    }

    /// 指定時刻にシークする
    pub fn seek(&mut self, time: f32) {
        self.elapsed_time = time;
    }

    // =========================================================================
    // レイヤー管理
    // =========================================================================

    /// レイヤーを追加する（最上面に追加）
    pub fn add_layer(
        &mut self,
        name: &str,
        width: u32,
        height: u32,
        rgba_data: &[u8],
    ) -> String {
        let layer = Layer::new(
            &self.device,
            &self.queue,
            &self.compositor.layer_bind_group_layout,
            &self.compositor.sampler,
            name,
            width,
            height,
            rgba_data,
        );
        let id = layer.id.clone();
        self.layer_index.insert(id.clone(), self.layers.len());
        self.layers.push(layer);
        id
    }

    /// レイヤーを削除する
    pub fn remove_layer(&mut self, layer_id: &str) -> bool {
        if let Some(&index) = self.layer_index.get(layer_id) {
            self.layers.remove(index);
            self.rebuild_index();
            log::info!("レイヤー削除: {}", layer_id);
            true
        } else {
            log::warn!("レイヤーが見つかりません: {}", layer_id);
            false
        }
    }

    /// レイヤーの描画順序を変更する（new_index は remove 後の配列における挿入位置）
    pub fn reorder_layer(&mut self, layer_id: &str, new_index: u32) -> bool {
        if let Some(&old_index) = self.layer_index.get(layer_id) {
            let new_idx = new_index as usize;
            if old_index == new_idx {
                return true;
            }
            let layer = self.layers.remove(old_index);
            let insert_idx = new_idx.min(self.layers.len());
            self.layers.insert(insert_idx, layer);
            self.rebuild_index();
            true
        } else {
            false
        }
    }

    /// レイヤーIDを下から順の配列で渡し、Rust 内部の合成順を Swift と完全一致させる
    pub fn set_layer_stack_order(&mut self, ordered_ids: &[String]) -> bool {
        if ordered_ids.len() != self.layers.len() {
            log::warn!(
                "set_layer_stack_order: 件数不一致 engine={} arg={}",
                self.layers.len(),
                ordered_ids.len()
            );
            return false;
        }
        let layer_ids: HashSet<&String> = self.layers.iter().map(|l| &l.id).collect();
        let mut seen: HashSet<&str> = HashSet::new();
        for id in ordered_ids {
            if !layer_ids.contains(id) || !seen.insert(id.as_str()) {
                log::warn!("set_layer_stack_order: 無効または重複ID");
                return false;
            }
        }
        let mut by_id: HashMap<String, Layer> = self.layers.drain(..).map(|l| (l.id.clone(), l)).collect();
        let mut new_layers = Vec::with_capacity(ordered_ids.len());
        for id in ordered_ids {
            if let Some(l) = by_id.remove(id) {
                new_layers.push(l);
            }
        }
        self.layers = new_layers;
        self.rebuild_index();
        true
    }

    /// レイヤーの変形を設定する（JSON文字列）
    pub fn set_layer_transform(&mut self, layer_id: &str, transform_json: &str) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            match serde_json::from_str::<LayerTransform>(transform_json) {
                Ok(transform) => layer.transform = transform,
                Err(e) => log::error!("変形JSON解析エラー: {}", e),
            }
        }
    }

    /// レイヤーの不透明度を設定する
    pub fn set_layer_opacity(&mut self, layer_id: &str, opacity: f32) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            layer.opacity = opacity.clamp(0.0, 1.0);
        }
    }

    /// レイヤーのブレンドモードを設定する
    pub fn set_layer_blend_mode(&mut self, layer_id: &str, blend_mode: u32) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            layer.blend_mode = BlendMode::from(blend_mode);
        }
    }

    /// レイヤーの表示/非表示を設定する
    pub fn set_layer_visible(&mut self, layer_id: &str, visible: bool) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            layer.visible = visible;
        }
    }

    /// レイヤーにアニメーション設定を適用する（JSON文字列）
    pub fn set_layer_animation(&mut self, layer_id: &str, config_json: &str) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            match serde_json::from_str::<AnimationConfig>(config_json) {
                Ok(config) => {
                    log::info!(
                        "アニメーション設定: レイヤー={}, プリセット={:?}",
                        layer_id,
                        config.preset
                    );
                    layer.animation_config = Some(config);
                }
                Err(e) => log::error!("アニメーションJSON解析エラー: {}", e),
            }
        }
    }

    /// レイヤーの画像調整パラメータを設定する（JSON文字列）
    pub fn set_layer_adjustments(&mut self, layer_id: &str, adjustments_json: &str) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            match serde_json::from_str::<ImageAdjustments>(adjustments_json) {
                Ok(adj) => {
                    layer.adjustments = adj;
                }
                Err(e) => log::error!("画像調整JSON解析エラー: {}", e),
            }
        }
    }

    /// エディタ用変形を設定する（JSON文字列）
    pub fn set_layer_editor_transform(&mut self, layer_id: &str, transform_json: &str) {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            match serde_json::from_str::<EditorTransform>(transform_json) {
                Ok(et) => {
                    layer.editor_transform = Some(et);
                }
                Err(e) => log::error!("エディタ変形JSON解析エラー: {}", e),
            }
        }
    }

    /// レイヤーテクスチャを更新する（動画フレーム差し替え用）
    pub fn update_layer_texture(
        &mut self,
        layer_id: &str,
        width: u32,
        height: u32,
        rgba_data: &[u8],
    ) {
        let idx = match self.layer_index.get(layer_id) {
            Some(&i) => i,
            None => return,
        };
        self.layers[idx].update_texture(
            &self.device,
            &self.queue,
            &self.compositor.layer_bind_group_layout,
            &self.compositor.sampler,
            width,
            height,
            rgba_data,
        );
    }

    /// ファイルパスから画像を読み込んでレイヤーを追加する
    pub fn add_layer_from_file(&mut self, name: &str, file_path: &str) -> Result<String, String> {
        let img = image::open(file_path).map_err(|e| format!("画像読み込み失敗: {}", e))?;
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let data = rgba.into_raw();
        Ok(self.add_layer(name, w, h, &data))
    }

    /// 合成結果をバイト列として取得する（エクスポート用）
    /// 常にキャンバスサイズでレンダリングする
    pub fn export_rgba(&mut self) -> (Vec<u8>, u32, u32) {
        // ビューポートモード中はキャンバスモードに切り替えてエクスポート
        let was_viewport = self.viewport_mode;
        if was_viewport {
            self.viewport_mode = false;
            self.compositor
                .resize(&self.device, self.canvas_width, self.canvas_height);
        }

        // キャンバスモードでレンダリング
        self.render_canvas_frame();

        let bytes_per_row = self.canvas_width * 4;
        let total_size = (bytes_per_row * self.canvas_height) as usize;
        let mut result = vec![0u8; total_size];
        self.iosurface.read_pixels(&mut result);

        // ビューポートモードに復帰
        if was_viewport {
            self.viewport_mode = true;
            self.compositor
                .resize(&self.device, self.viewport_width, self.viewport_height);
        }

        (result, self.canvas_width, self.canvas_height)
    }

    // =========================================================================
    // 水流ブラシ（FlowField）
    // =========================================================================

    /// 指定レイヤーに水流ブラシを適用する
    ///
    /// points: レイヤー画像座標系の点列（ストローク経路）
    /// radius: ブラシ半径（ピクセル）
    /// strength: 速度の強さ（UV単位/秒、推奨範囲 0.05 - 0.5）
    /// softness: フォールオフ（0.05 - 1.0、大きいほど中心に集中）
    pub fn paint_flow_stroke(
        &mut self,
        layer_id: &str,
        points: &[(f32, f32)],
        radius: f32,
        strength: f32,
        softness: f32,
    ) -> bool {
        let idx = match self.layer_index.get(layer_id) {
            Some(&i) => i,
            None => {
                log::warn!("paint_flow_stroke: レイヤー未検出 {}", layer_id);
                return false;
            }
        };
        let layer = &mut self.layers[idx];
        // FlowField を遅延生成（レイヤー解像度と一致）
        if layer.flow_field.is_none() {
            let ff = crate::motion::FlowField::new(
                &self.device,
                &self.compositor.flow_bind_group_layout,
                &self.compositor.flow_sampler,
                &self.compositor.flow_uniform_buffer,
                layer.width,
                layer.height,
            );
            layer.flow_field = Some(ff);
        }
        let ff = layer.flow_field.as_mut().unwrap();
        ff.paint_stroke(points, radius, strength, softness);
        // ペイントしたら自動で有効化
        ff.params.enabled = 1;
        ff.upload_if_dirty(&self.queue);
        true
    }

    /// 指定レイヤーのフローフィールドをクリアする
    pub fn clear_flow_field(&mut self, layer_id: &str) -> bool {
        let idx = match self.layer_index.get(layer_id) {
            Some(&i) => i,
            None => return false,
        };
        if let Some(ff) = self.layers[idx].flow_field.as_mut() {
            ff.clear();
            ff.upload_if_dirty(&self.queue);
            true
        } else {
            false
        }
    }

    /// フローフィールドのパラメータを設定する
    /// enabled=false 時は通常のレイヤーレンダリングに戻る
    pub fn set_flow_params(
        &mut self,
        layer_id: &str,
        enabled: bool,
        loop_duration: f32,
        speed_scale: f32,
    ) -> bool {
        let idx = match self.layer_index.get(layer_id) {
            Some(&i) => i,
            None => return false,
        };
        let layer = &mut self.layers[idx];
        // 設定するときに FlowField が無ければ生成しておく
        if layer.flow_field.is_none() && enabled {
            let ff = crate::motion::FlowField::new(
                &self.device,
                &self.compositor.flow_bind_group_layout,
                &self.compositor.flow_sampler,
                &self.compositor.flow_uniform_buffer,
                layer.width,
                layer.height,
            );
            layer.flow_field = Some(ff);
        }
        if let Some(ff) = layer.flow_field.as_mut() {
            ff.params.enabled = if enabled { 1 } else { 0 };
            ff.params.loop_duration = loop_duration.max(0.1);
            ff.params.speed_scale = speed_scale.max(0.0);
            true
        } else {
            false
        }
    }

    // =========================================================================
    // マスク編集（GPUブラシ用のフック）
    // =========================================================================

    /// マスクテクスチャを外部から設定する（R8フォーマット）
    pub fn set_mask_texture(&mut self, width: u32, height: u32, data: &[u8]) {
        let w = width.max(1);
        let h = height.max(1);
        let expected = (w as usize) * (h as usize);

        self.mask_width = w;
        self.mask_height = h;
        self.mask_pixels.resize(expected, 255);

        let copy_len = expected.min(data.len());
        self.mask_pixels[..copy_len].copy_from_slice(&data[..copy_len]);
        if copy_len < expected {
            for px in &mut self.mask_pixels[copy_len..] {
                *px = 255;
            }
        }
        self.compositor.resize_mask_canvas(&self.device, w, h);
        self.mask_gpu_dirty = true;
    }

    /// マスクをリセット（全ピクセル白 = 合成に影響しない）
    pub fn clear_mask(&mut self) {
        if self.mask_width == 0 || self.mask_height == 0 {
            return;
        }
        let len = (self.mask_width as usize) * (self.mask_height as usize);
        self.mask_pixels.resize(len, 255);
        for px in &mut self.mask_pixels {
            *px = 255;
        }
        self.mask_gpu_dirty = true;
    }

    /// キャンバス座標の矩形領域にマスク値を塗る（切り抜き・範囲ペイント用）
    pub fn fill_mask_rect(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, value: u8) {
        let min_x = x0.min(x1).floor() as i32;
        let max_x = x0.max(x1).ceil() as i32;
        let min_y = y0.min(y1).floor() as i32;
        let max_y = y0.max(y1).ceil() as i32;
        let width = self.mask_width as i32;
        let height = self.mask_height as i32;
        if width <= 0 || height <= 0 {
            return;
        }
        let min_x = min_x.max(0);
        let min_y = min_y.max(0);
        let max_x = max_x.min(width - 1);
        let max_y = max_y.min(height - 1);
        for y in min_y..=max_y {
            let row = (y as usize) * (width as usize);
            for x in min_x..=max_x {
                let idx = row + (x as usize);
                if let Some(px) = self.mask_pixels.get_mut(idx) {
                    *px = value;
                }
            }
        }
        self.mask_gpu_dirty = true;
    }

    /// マスクにブラシストロークを適用する
    /// points は画像座標系の点列（ストロークの経路）
    /// 現時点ではCPU側でマスクバッファに反映する
    pub fn paint_mask_stroke(
        &mut self,
        points: &[(f32, f32)],
        radius: f32,
        softness: f32,
        is_erasing: bool,
    ) {
        if points.is_empty() || radius <= 0.0 {
            return;
        }
        if self.mask_width == 0 || self.mask_height == 0 {
            return;
        }

        let radius_i = radius.max(1.0) as i32;
        let radius_sq = radius_i * radius_i;
        let radius_f = radius.max(1.0);

        let width = self.mask_width as i32;
        let height = self.mask_height as i32;

        // フォールオフLUTを事前計算（Swift側MaskData::paintと同等のロジック）
        let clamped_softness = softness.max(0.01);
        let inv_soft = 1.0 / clamped_softness;
        let mut falloff_lut = vec![0.0f32; (radius_i + 1) as usize];
        for d in 0..=radius_i {
            let dist = (d as f32) / radius_f;
            let v = (1.0 - dist.powf(inv_soft)).max(0.0);
            falloff_lut[d as usize] = v;
        }

        let max_mask = 255.0f32;

        for &(px, py) in points {
            let cx = px.round() as i32;
            let cy = py.round() as i32;

            let min_x = (cx - radius_i).max(0);
            let max_x = (cx + radius_i).min(width - 1);
            let min_y = (cy - radius_i).max(0);
            let max_y = (cy + radius_i).min(height - 1);

            for y in min_y..=max_y {
                let dy = y - cy;
                let row_offset = (y as usize) * (width as usize);
                for x in min_x..=max_x {
                    let dx = x - cx;
                    let dist_sq = dx * dx + dy * dy;
                    if dist_sq <= radius_sq {
                        let dist = (dist_sq as f32).sqrt() as i32;
                        let falloff = falloff_lut[dist.min(radius_i) as usize];
                        let idx = row_offset + (x as usize);
                        let current = self.mask_pixels[idx] as f32;

                        if is_erasing {
                            let erase_amount = max_mask * falloff;
                            let new_val = (current - erase_amount).max(0.0);
                            self.mask_pixels[idx] = new_val as u8;
                        } else {
                            let strength = max_mask * falloff;
                            let new_val = current.max(strength).min(max_mask);
                            self.mask_pixels[idx] = new_val as u8;
                        }
                    }
                }
            }
        }
        self.mask_gpu_dirty = true;
    }

    /// マスクをぼかす（簡易ボックスブラー）
    pub fn blur_mask(&mut self, radius: u32) {
        let radius = radius as i32;
        if radius <= 0 {
            return;
        }
        if self.mask_width == 0 || self.mask_height == 0 {
            return;
        }

        let width = self.mask_width as i32;
        let height = self.mask_height as i32;
        let mut temp = self.mask_pixels.clone();

        for y in 0..height {
            for x in 0..width {
                let min_x = (x - radius).max(0);
                let max_x = (x + radius).min(width - 1);
                let min_y = (y - radius).max(0);
                let max_y = (y + radius).min(height - 1);

                let mut sum = 0u32;
                let mut count = 0u32;

                for yy in min_y..=max_y {
                    let row_offset = (yy as usize) * (width as usize);
                    for xx in min_x..=max_x {
                        let idx = row_offset + (xx as usize);
                        sum += self.mask_pixels[idx] as u32;
                        count += 1;
                    }
                }

                let idx = (y as usize) * (width as usize) + (x as usize);
                temp[idx] = if count > 0 {
                    (sum / count) as u8
                } else {
                    self.mask_pixels[idx]
                };
            }
        }

        self.mask_pixels = temp;
        self.mask_gpu_dirty = true;
    }

    /// マスクを反転する
    pub fn invert_mask(&mut self) {
        if self.mask_pixels.is_empty() {
            return;
        }
        for px in &mut self.mask_pixels {
            *px = 255u8.saturating_sub(*px);
        }
        self.mask_gpu_dirty = true;
    }

    // =========================================================================
    // 内部ヘルパー
    // =========================================================================

    fn mask_identity(&self) -> bool {
        self.mask_pixels.iter().all(|&p| p == 255)
    }

    fn upload_mask_gpu(&mut self) {
        let w = self.mask_width;
        let h = self.mask_height;
        if w == 0 || h == 0 {
            return;
        }
        if self.compositor.mask_canvas_width != w || self.compositor.mask_canvas_height != h {
            self.compositor.resize_mask_canvas(&self.device, w, h);
        }
        let unpadded_bpr = w;
        let padded_bpr = (unpadded_bpr + 255) & !255;
        if padded_bpr == unpadded_bpr {
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &self.compositor.mask_texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &self.mask_pixels,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(unpadded_bpr),
                    rows_per_image: Some(h),
                },
                wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
            );
        } else {
            let mut padded = Vec::with_capacity((padded_bpr * h) as usize);
            for row in 0..h {
                let start = (row * w) as usize;
                padded.extend_from_slice(&self.mask_pixels[start..start + w as usize]);
                for _ in unpadded_bpr..padded_bpr {
                    padded.push(0);
                }
            }
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &self.compositor.mask_texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &padded,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded_bpr),
                    rows_per_image: Some(h),
                },
                wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
            );
        }
    }

    /// デバッグ用: アクティブIOSurfaceに赤いテストパターンを書き込む
    /// パイプラインの各段階を個別に検証するために使用
    pub fn debug_fill_iosurface(&self) {
        let (ios, w, h) = if self.viewport_mode {
            if let Some(ref ios) = self.viewport_iosurface {
                (ios, self.viewport_width, self.viewport_height)
            } else {
                log::error!("デバッグ塗りつぶし: ビューポートIOSurface未初期化");
                return;
            }
        } else {
            (&self.iosurface, self.canvas_width, self.canvas_height)
        };

        let pixel_count = (w * h) as usize;
        let mut data = vec![0u8; pixel_count * 4];
        for i in 0..pixel_count {
            // BGRA形式: 赤色 (B=0, G=0, R=255, A=255)
            data[i * 4 + 0] = 0;     // B
            data[i * 4 + 1] = 0;     // G
            data[i * 4 + 2] = 255;   // R
            data[i * 4 + 3] = 255;   // A
        }
        ios.write_pixels(&data);
        log::info!(
            "デバッグ: IOSurfaceに赤色テストパターン書き込み ({}x{}, mode={})",
            w, h, if self.viewport_mode { "viewport" } else { "canvas" }
        );
    }

    fn get_layer_mut(&mut self, layer_id: &str) -> Option<&mut Layer> {
        self.layer_index
            .get(layer_id)
            .and_then(|&idx| self.layers.get_mut(idx))
    }

    fn rebuild_index(&mut self) {
        self.layer_index.clear();
        for (i, layer) in self.layers.iter().enumerate() {
            self.layer_index.insert(layer.id.clone(), i);
        }
    }

    // =========================================================================
    // ParticleSystem (Phase 4A)
    // =========================================================================

    /// パーティクルシステムを追加する。
    /// - Returns: 発行された ParticleSystemId.0 (u32)。
    /// Why: FFI 側から JSON descriptor を渡しやすいよう、Engine 直叩きの API は
    ///      高レベルの Descriptor 構造体を受ける。
    pub fn add_particle_system(
        &mut self,
        descriptor: crate::particle::ParticleSystemDescriptor,
    ) -> u32 {
        let id = crate::particle::ParticleSystemId(self.next_particle_id);
        self.next_particle_id = self.next_particle_id.saturating_add(1);
        let system = crate::particle::ParticleSystem::new(id, descriptor);
        self.particle_systems.push(system);
        id.0
    }

    /// 既存パーティクルシステムにパラメータを部分適用する。
    /// - Returns: 該当 id が見つかれば true。
    pub fn update_particle_system(
        &mut self,
        id: u32,
        params: crate::particle::ParticleSystemParams,
    ) -> bool {
        if let Some(sys) = self
            .particle_systems
            .iter_mut()
            .find(|s| s.id.0 == id)
        {
            sys.apply_params(params);
            true
        } else {
            false
        }
    }

    /// パーティクルシステムを削除する。
    pub fn remove_particle_system(&mut self, id: u32) -> bool {
        let len_before = self.particle_systems.len();
        self.particle_systems.retain(|s| s.id.0 != id);
        self.particle_systems.len() != len_before
    }

    /// 現在登録されているパーティクルシステム数を返す (テスト/メトリクス用)。
    pub fn particle_system_count(&self) -> usize {
        self.particle_systems.len()
    }

    /// 指定 ID のパーティクルシステムへの不変参照 (テスト用)。
    pub fn particle_system_ref(&self, id: u32) -> Option<&crate::particle::ParticleSystem> {
        self.particle_systems.iter().find(|s| s.id.0 == id)
    }

    // =========================================================================
    // Audio Reactive (Phase 6A)
    // =========================================================================

    /// Swift 側で計算した FFT バンドを uniform へ書き込む。
    /// - `bands`: 0..1 に正規化された振幅。最大 MAX_AUDIO_BANDS 件。
    /// - `time`: シェーダ位相用の経過時間 (秒)。
    pub fn update_audio_uniform(&mut self, bands: &[f32], time: f32) {
        self.audio_uniform.update(bands, time);
    }

    /// 現在の audio uniform への不変参照 (テスト / FFI バインディング用)。
    pub fn audio_uniform(&self) -> &crate::audio::AudioUniform {
        &self.audio_uniform
    }

    /// 指定パーティクルシステムに audio binding を設定する。
    /// - Returns: 該当 ID が見つかれば true。
    pub fn set_particle_audio_binding(
        &mut self,
        id: u32,
        binding: Option<crate::audio::EmitterAudioBinding>,
    ) -> bool {
        if let Some(sys) = self.particle_systems.iter_mut().find(|s| s.id.0 == id) {
            sys.audio_binding = binding;
            true
        } else {
            false
        }
    }

    /// 指定パーティクルシステムの直近の emit rate (audio 変調込み) を返す (テスト用)。
    pub fn particle_modulated_rate(&self, id: u32) -> Option<f32> {
        self.particle_systems
            .iter()
            .find(|s| s.id.0 == id)
            .map(|s| {
                let base = s.emitter.spawn_rate;
                if let Some(b) = s.audio_binding {
                    b.modulated_rate(base, &self.audio_uniform)
                } else {
                    base
                }
            })
    }

    // =========================================================================
    // パララックス (Phase 4B)
    // =========================================================================

    /// 指定レイヤーにパララックス設定を割り当てる。
    /// - Returns: 該当レイヤーが見つかれば true。
    pub fn set_parallax_layer(
        &mut self,
        layer_id: &str,
        setting: crate::parallax::ParallaxLayerSetting,
    ) -> bool {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            layer.parallax = Some(setting);
            true
        } else {
            false
        }
    }

    /// 指定レイヤーのパララックス設定を解除する。
    pub fn clear_parallax_layer(&mut self, layer_id: &str) -> bool {
        if let Some(layer) = self.get_layer_mut(layer_id) {
            layer.parallax = None;
            layer.parallax_offset = [0.0, 0.0];
            true
        } else {
            false
        }
    }

    /// グローバルマウスオフセットを更新する (-1.0 .. 1.0 を期待)。
    /// Why: ParallaxController から 60fps で呼ばれる。値は次フレームの render_frame で
    ///      各レイヤーの parallax_offset に展開される。
    pub fn update_parallax(&mut self, mouse_x_norm: f32, mouse_y_norm: f32) {
        let n = crate::parallax::NormalizedMouseOffset::new(mouse_x_norm, mouse_y_norm);
        self.parallax_mouse = n.as_array();
    }

    /// 現在のパララックスマウスオフセットを返す (テスト用)。
    pub fn parallax_mouse(&self) -> [f32; 2] {
        self.parallax_mouse
    }

    // =========================================================================
    // Light レイヤー (Phase 4B)
    // =========================================================================

    /// Light レイヤーを追加する。
    /// - Returns: 発行された LightLayerId.0 (1 以上)。
    pub fn add_light_layer(&mut self, descriptor: crate::light::LightLayerDescriptor) -> u32 {
        let id = crate::light::LightLayerId(self.next_light_id);
        self.next_light_id = self.next_light_id.saturating_add(1);
        self.light_layers
            .push(crate::light::LightLayer::new(id, descriptor));
        id.0
    }

    /// Light レイヤーにパラメータを部分適用する。
    pub fn update_light_layer(
        &mut self,
        id: u32,
        params: crate::light::LightLayerParams,
    ) -> bool {
        if let Some(light) = self.light_layers.iter_mut().find(|l| l.id.0 == id) {
            light.apply_params(params);
            true
        } else {
            false
        }
    }

    /// Light レイヤーを削除する。
    pub fn remove_light_layer(&mut self, id: u32) -> bool {
        let len_before = self.light_layers.len();
        self.light_layers.retain(|l| l.id.0 != id);
        self.light_layers.len() != len_before
    }

    /// 現在の Light レイヤー数 (テスト/メトリクス用)。
    pub fn light_layer_count(&self) -> usize {
        self.light_layers.len()
    }

    /// 指定 ID の Light レイヤーへの不変参照 (テスト用)。
    pub fn light_layer_ref(&self, id: u32) -> Option<&crate::light::LightLayer> {
        self.light_layers.iter().find(|l| l.id.0 == id)
    }

    // =========================================================================
    // PuppetWarp (Phase 4C)
    // =========================================================================

    /// PuppetWarp を追加する。
    /// - Returns: 発行された PuppetWarpId.0 (1 以上)。
    pub fn add_puppet_warp(&mut self, descriptor: crate::warp::PuppetWarpDescriptor) -> u32 {
        let id = crate::warp::PuppetWarpId(self.next_puppet_warp_id);
        self.next_puppet_warp_id = self.next_puppet_warp_id.saturating_add(1);
        self.puppet_warps
            .push(crate::warp::PuppetWarp::new(id, descriptor));
        id.0
    }

    /// PuppetWarp に handle / 解法パラメータを部分適用する。
    pub fn update_puppet_warp(
        &mut self,
        id: u32,
        params: crate::warp::PuppetWarpParams,
    ) -> bool {
        if let Some(w) = self.puppet_warps.iter_mut().find(|w| w.id.0 == id) {
            w.apply_params(params);
            true
        } else {
            false
        }
    }

    /// PuppetWarp を破棄する。
    pub fn remove_puppet_warp(&mut self, id: u32) -> bool {
        let len_before = self.puppet_warps.len();
        self.puppet_warps.retain(|w| w.id.0 != id);
        self.puppet_warps.len() != len_before
    }

    pub fn puppet_warp_count(&self) -> usize {
        self.puppet_warps.len()
    }

    pub fn puppet_warp_ref(&self, id: u32) -> Option<&crate::warp::PuppetWarp> {
        self.puppet_warps.iter().find(|w| w.id.0 == id)
    }

    // =========================================================================
    // Skeleton (Phase 4C)
    // =========================================================================

    /// Skeleton を追加する。
    /// - Returns: 発行された SkeletonId.0 (1 以上)。
    pub fn add_skeleton(&mut self, descriptor: crate::bone::SkeletonDescriptor) -> u32 {
        let id = crate::bone::SkeletonId(self.next_skeleton_id);
        self.next_skeleton_id = self.next_skeleton_id.saturating_add(1);
        self.skeletons
            .push(crate::bone::Skeleton::new(id, descriptor));
        id.0
    }

    /// Skeleton の pose を一括差し替えして FK + LBS を再計算する。
    /// - Returns: bone_count に一致しなければ false。
    pub fn update_skeleton_pose(
        &mut self,
        id: u32,
        params: crate::bone::SkeletonPoseParams,
    ) -> bool {
        if let Some(s) = self.skeletons.iter_mut().find(|s| s.id.0 == id) {
            s.apply_pose(params)
        } else {
            false
        }
    }

    /// Skeleton を破棄する。
    pub fn remove_skeleton(&mut self, id: u32) -> bool {
        let len_before = self.skeletons.len();
        self.skeletons.retain(|s| s.id.0 != id);
        self.skeletons.len() != len_before
    }

    pub fn skeleton_count(&self) -> usize {
        self.skeletons.len()
    }

    pub fn skeleton_ref(&self, id: u32) -> Option<&crate::bone::Skeleton> {
        self.skeletons.iter().find(|s| s.id.0 == id)
    }
}
