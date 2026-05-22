// 水流ブラシ用フローフィールド
// 各ピクセルに2D速度ベクトル(vx, vy)を保持し、シェーダー側でUV変位に利用する
//
// データ表現:
// - CPU側: Vec<[f32; 2]> をフィールド全体で保持（ペイントはCPUで実行）
// - GPU側: Rg16Float テクスチャに反映（レイヤーシェーダーがサンプリング）
//
// ベクトル単位: 正規化UV座標系での速度（1.0 = テクスチャ全体を1秒で横断）
// 通常は -1.0 ~ +1.0 の範囲で十分

use bytemuck::{Pod, Zeroable};

/// シェーダーへ渡すフローフィールドパラメータ（16バイトアラインメント）
#[derive(Debug, Clone, Copy, Pod, Zeroable)]
#[repr(C)]
pub struct FlowFieldParams {
    /// フローフィールド有効フラグ（0 = 無効, 1 = 有効）
    pub enabled: u32,
    /// ループ周期（秒）。フェードクロスでこの周期ごとに元画像へ戻す
    pub loop_duration: f32,
    /// 速度倍率（フィールドの強さをまとめてスケール）
    pub speed_scale: f32,
    /// 経過時間（秒）
    pub time: f32,
    /// フィールドサイズ（テクセル数）
    pub field_size: [f32; 2],
    /// 16バイトアラインメント用パディング
    pub _padding: [f32; 2],
}

impl Default for FlowFieldParams {
    fn default() -> Self {
        Self {
            enabled: 0,
            loop_duration: 2.0,
            speed_scale: 0.15,
            time: 0.0,
            field_size: [0.0, 0.0],
            _padding: [0.0; 2],
        }
    }
}

/// レイヤーに付随するフローフィールド
///
/// width × height のRg16Floatテクスチャを保持し、ペイント時にCPUバッファを更新→GPU転送する
pub struct FlowField {
    /// フィールド幅（テクセル）
    pub width: u32,
    /// フィールド高さ（テクセル）
    pub height: u32,
    /// 速度ベクトル（vx, vy）。長さは width * height
    pub vectors: Vec<[f32; 2]>,
    /// GPUテクスチャ（Rg16Float）
    pub texture: wgpu::Texture,
    pub texture_view: wgpu::TextureView,
    /// バインドグループ（group=3 で composite シェーダーへ供給）
    pub bind_group: wgpu::BindGroup,
    /// CPU→GPU 未反映フラグ
    pub gpu_dirty: bool,
    /// シェーダーへ渡すパラメータ
    pub params: FlowFieldParams,
}

impl FlowField {
    /// 新規作成（全ベクトル = ゼロ）
    ///
    /// bind_group_layout は Compositor::flow_bind_group_layout を渡す
    /// uniform_buffer は Compositor::flow_uniform_buffer を渡す（描画前に毎回更新する共有バッファ）
    pub fn new(
        device: &wgpu::Device,
        bind_group_layout: &wgpu::BindGroupLayout,
        sampler: &wgpu::Sampler,
        uniform_buffer: &wgpu::Buffer,
        width: u32,
        height: u32,
    ) -> Self {
        let w = width.max(1);
        let h = height.max(1);
        let vectors = vec![[0.0f32, 0.0f32]; (w as usize) * (h as usize)];

        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("フローフィールドテクスチャ Rg16Float"),
            size: wgpu::Extent3d {
                width: w,
                height: h,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rg16Float,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });

        let texture_view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("フローフィールドBG"),
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
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: uniform_buffer.as_entire_binding(),
                },
            ],
        });

        let mut params = FlowFieldParams::default();
        params.field_size = [w as f32, h as f32];

        Self {
            width: w,
            height: h,
            vectors,
            texture,
            texture_view,
            bind_group,
            gpu_dirty: true,
            params,
        }
    }

    /// 全ベクトルをクリアする
    pub fn clear(&mut self) {
        for v in &mut self.vectors {
            *v = [0.0, 0.0];
        }
        self.gpu_dirty = true;
    }

    /// ストロークをペイントする
    ///
    /// points: レイヤー画像座標系（0..width, 0..height）の点列
    /// radius: ブラシ半径（ピクセル）
    /// strength: ベクトル強度（0..1 推奨）
    /// softness: フォールオフ（0..1、大きいほど中心に集中）
    pub fn paint_stroke(
        &mut self,
        points: &[(f32, f32)],
        radius: f32,
        strength: f32,
        softness: f32,
    ) {
        if points.len() < 1 || radius <= 0.0 || self.width == 0 || self.height == 0 {
            return;
        }
        let radius_i = radius.max(1.0) as i32;
        let radius_sq = (radius_i * radius_i) as f32;
        let radius_f = radius.max(1.0);
        let clamped_softness = softness.clamp(0.05, 1.0);
        let inv_soft = 1.0 / clamped_softness;
        let width_i = self.width as i32;
        let height_i = self.height as i32;

        // 各セグメント（点iと点i+1）でベクトル方向を決定し、点iの周辺に書き込む
        for i in 0..points.len() {
            let (px, py) = points[i];
            // 方向ベクトル: 次の点へ向かう方向（最終点は前の点からの方向を流用）
            let (dir_x, dir_y) = if i + 1 < points.len() {
                let (nx, ny) = points[i + 1];
                let dx = nx - px;
                let dy = ny - py;
                let len = (dx * dx + dy * dy).sqrt().max(1e-3);
                (dx / len, dy / len)
            } else if i > 0 {
                let (px2, py2) = points[i - 1];
                let dx = px - px2;
                let dy = py - py2;
                let len = (dx * dx + dy * dy).sqrt().max(1e-3);
                (dx / len, dy / len)
            } else {
                continue;
            };

            // UV空間でのベクトルへ変換（テクスチャ座標は0..1）
            // ピクセル単位の方向 → UV単位の速度ベクトル
            // strength は1秒あたりに動かす UV 距離（おおよそ）
            let vx = dir_x * strength;
            let vy = dir_y * strength;

            let cx = px.round() as i32;
            let cy = py.round() as i32;
            let min_x = (cx - radius_i).max(0);
            let max_x = (cx + radius_i).min(width_i - 1);
            let min_y = (cy - radius_i).max(0);
            let max_y = (cy + radius_i).min(height_i - 1);

            for y in min_y..=max_y {
                let dy = (y - cy) as f32;
                let row = (y as usize) * (self.width as usize);
                for x in min_x..=max_x {
                    let dx = (x - cx) as f32;
                    let dist_sq = dx * dx + dy * dy;
                    if dist_sq > radius_sq {
                        continue;
                    }
                    let dist = dist_sq.sqrt() / radius_f;
                    let falloff = (1.0 - dist.powf(inv_soft)).max(0.0);
                    if falloff <= 0.0 {
                        continue;
                    }
                    let idx = row + (x as usize);
                    // 既存ベクトルとブレンド（重ね塗りで方向が滑らかに変化）
                    let cur = self.vectors[idx];
                    let blend = falloff;
                    let new_x = cur[0] * (1.0 - blend) + vx * blend;
                    let new_y = cur[1] * (1.0 - blend) + vy * blend;
                    self.vectors[idx] = [new_x, new_y];
                }
            }
        }
        self.gpu_dirty = true;
    }

    /// CPU 側ベクトルを GPU テクスチャへ転送する（dirty 時のみ）
    pub fn upload_if_dirty(&mut self, queue: &wgpu::Queue) {
        if !self.gpu_dirty {
            return;
        }
        // Rg16Float = 4バイト/テクセル（half * 2）
        let mut pixel_bytes = Vec::with_capacity(self.vectors.len() * 4);
        for v in &self.vectors {
            let hx = half::f16::from_f32(v[0]).to_bits();
            let hy = half::f16::from_f32(v[1]).to_bits();
            pixel_bytes.extend_from_slice(&hx.to_le_bytes());
            pixel_bytes.extend_from_slice(&hy.to_le_bytes());
        }
        let bytes_per_row = self.width * 4;
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &pixel_bytes,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(bytes_per_row),
                rows_per_image: Some(self.height),
            },
            wgpu::Extent3d {
                width: self.width,
                height: self.height,
                depth_or_array_layers: 1,
            },
        );
        self.gpu_dirty = false;
    }
}
