// レイヤー変形・ブレンドモード・画像調整等の共有型定義

use serde::Deserialize;

/// 画像調整パラメータ
/// Swift側の ImageAdjustments と互換
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct ImageAdjustments {
    #[serde(default)]
    pub brightness: f32,
    #[serde(default = "default_one")]
    pub contrast: f32,
    #[serde(default = "default_one")]
    pub saturation: f32,
    #[serde(default)]
    pub temperature: f32,
    #[serde(default)]
    pub sharpness: f32,
    #[serde(default = "default_one")]
    pub gamma: f32,
    #[serde(default)]
    pub exposure: f32,
    #[serde(default)]
    pub filter_type: u32,
}

fn default_one() -> f32 {
    1.0
}

impl Default for ImageAdjustments {
    fn default() -> Self {
        Self {
            brightness: 0.0,
            contrast: 1.0,
            saturation: 1.0,
            temperature: 0.0,
            sharpness: 0.0,
            gamma: 1.0,
            exposure: 0.0,
            filter_type: 0,
        }
    }
}

/// レイヤーの変形パラメータ
/// Swift側JSONと一致: {"position":[x,y],"scale":[sx,sy],"rotation":rad,"anchor":[ax,ay],"depth":d}
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct LayerTransform {
    #[serde(default)]
    pub position: [f32; 2],
    #[serde(default = "default_scale")]
    pub scale: [f32; 2],
    #[serde(default)]
    pub rotation: f32,
    #[serde(default = "default_anchor")]
    pub anchor: [f32; 2],
    #[serde(default)]
    pub depth: f32,
}

fn default_scale() -> [f32; 2] {
    [1.0, 1.0]
}

fn default_anchor() -> [f32; 2] {
    [0.5, 0.5]
}

impl Default for LayerTransform {
    fn default() -> Self {
        Self {
            position: [0.0, 0.0],
            scale: [1.0, 1.0],
            rotation: 0.0,
            anchor: [0.5, 0.5],
            depth: 0.0,
        }
    }
}

impl LayerTransform {
    /// 4x4変換行列を計算する（列優先）
    /// anchor中心にscale→rotation→positionの順で適用
    pub fn to_matrix(&self, canvas_width: f32, canvas_height: f32, layer_width: f32, layer_height: f32) -> [[f32; 4]; 4] {
        // レイヤーのアスペクト比を考慮したスケール
        let sx = self.scale[0] * layer_width / canvas_width;
        let sy = self.scale[1] * layer_height / canvas_height;

        // アンカーポイント（レイヤー空間での中心オフセット）
        let ax = (self.anchor[0] - 0.5) * 2.0;
        let ay = (self.anchor[1] - 0.5) * 2.0;

        // 位置オフセット（NDC空間）
        let tx = self.position[0] * 2.0 / canvas_width;
        let ty = -self.position[1] * 2.0 / canvas_height;

        let cos_r = self.rotation.cos();
        let sin_r = self.rotation.sin();

        // 変換行列: translate(position) * translate(anchor) * rotate * scale * translate(-anchor)
        // 列優先で格納
        [
            [sx * cos_r, sx * sin_r, 0.0, 0.0],
            [-sy * sin_r, sy * cos_r, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [
                tx + ax * sx * cos_r - ay * sy * sin_r - ax * cos_r + ay * sin_r,
                ty + ax * sx * sin_r + ay * sy * cos_r - ax * sin_r - ay * cos_r,
                0.0,
                1.0,
            ],
        ]
    }
}

/// エディタ用変形パラメータ
/// Swift側の LayerTransform (EditorModels.swift) と互換
/// offsetX/Y, scaleX/Y, rotation, flipH/V 方式
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct EditorTransform {
    #[serde(default, alias = "offsetX")]
    pub offset_x: f32,
    #[serde(default, alias = "offsetY")]
    pub offset_y: f32,
    #[serde(default = "default_one", alias = "scaleX")]
    pub scale_x: f32,
    #[serde(default = "default_one", alias = "scaleY")]
    pub scale_y: f32,
    #[serde(default)]
    pub rotation: f32,
    #[serde(default, alias = "flipHorizontal")]
    pub flip_h: bool,
    #[serde(default, alias = "flipVertical")]
    pub flip_v: bool,
}

impl Default for EditorTransform {
    fn default() -> Self {
        Self {
            offset_x: 0.0,
            offset_y: 0.0,
            scale_x: 1.0,
            scale_y: 1.0,
            rotation: 0.0,
            flip_h: false,
            flip_v: false,
        }
    }
}

impl EditorTransform {
    /// 4x4変換行列を計算する（列優先）
    /// Swift EditorShaders.metal の transformUV() と同じロジック
    pub fn to_matrix(
        &self,
        canvas_w: f32,
        canvas_h: f32,
        layer_w: f32,
        layer_h: f32,
    ) -> [[f32; 4]; 4] {
        // 反転を考慮したスケール
        let flip_x: f32 = if self.flip_h { -1.0 } else { 1.0 };
        let flip_y: f32 = if self.flip_v { -1.0 } else { 1.0 };
        let sx = self.scale_x * flip_x * layer_w / canvas_w;
        let sy = self.scale_y * flip_y * layer_h / canvas_h;

        // 位置オフセット（ピクセル→NDC変換）
        let tx = self.offset_x * 2.0 / canvas_w;
        let ty = -self.offset_y * 2.0 / canvas_h;

        let cos_r = self.rotation.cos();
        let sin_r = self.rotation.sin();

        // 変換行列: translate(position) * rotate * scale
        // 列優先で格納
        [
            [sx * cos_r, sx * sin_r, 0.0, 0.0],
            [-sy * sin_r, sy * cos_r, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [tx, ty, 0.0, 1.0],
        ]
    }
}

/// ブレンドモード
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum BlendMode {
    Normal = 0,
    Multiply = 1,
    Screen = 2,
    Overlay = 3,
    SoftLight = 4,
    HardLight = 5,
    Add = 6,
    Subtract = 7,
}

impl From<u32> for BlendMode {
    fn from(v: u32) -> Self {
        match v {
            1 => Self::Multiply,
            2 => Self::Screen,
            3 => Self::Overlay,
            4 => Self::SoftLight,
            5 => Self::HardLight,
            6 => Self::Add,
            7 => Self::Subtract,
            _ => Self::Normal,
        }
    }
}

/// GPU側に渡すレイヤーユニフォーム（128バイト、16バイトアラインメント）
#[derive(Debug, Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
#[repr(C)]
pub struct LayerUniforms {
    /// 4x4変換行列（列優先）
    pub transform: [[f32; 4]; 4],
    /// 不透明度
    pub opacity: f32,
    /// ブレンドモード
    pub blend_mode: u32,
    /// キャンバスサイズ
    pub canvas_size: [f32; 2],
    /// レイヤーサイズ
    pub layer_size: [f32; 2],
    // 画像調整パラメータ（32バイト）
    pub brightness: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub temperature: f32,
    pub sharpness: f32,
    pub gamma: f32,
    pub exposure: f32,
    pub filter_type: u32,
    /// 16バイトアラインメント用パディング（WGSLの構造体サイズは16の倍数に切り上げ）
    pub _padding: [f32; 2],
}

// =========================================================================
// ビューポート関連
// =========================================================================

/// ビューポートパラメータ（エディタ表示用）
/// Swift側の CanvasViewport と対応
#[derive(Debug, Clone, Copy)]
pub struct ViewportParams {
    /// ビューポート幅（ピクセル）
    pub viewport_width: f32,
    /// ビューポート高さ（ピクセル）
    pub viewport_height: f32,
    /// ズームレベル（totalScale = fitScale × zoomLevel）
    pub zoom: f32,
    /// パンオフセットX（スクリーンピクセル）
    #[allow(dead_code)]
    pub pan_x: f32,
    /// パンオフセットY（スクリーンピクセル）
    #[allow(dead_code)]
    pub pan_y: f32,
    /// キャンバス左上のビューポート内X座標
    pub canvas_origin_x: f32,
    /// キャンバス左上のビューポート内Y座標
    pub canvas_origin_y: f32,
}

/// マスク適用パス用（キャンバス R8 マスク → ビューポート合成）
#[derive(Debug, Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
#[repr(C)]
pub struct MaskApplyUniforms {
    pub viewport_size: [f32; 2],
    pub canvas_size: [f32; 2],
    pub canvas_origin: [f32; 2],
    pub zoom: f32,
    /// 1.0 = ビューポート→キャンバス UV 変換、0.0 = 1:1（キャンバスモード）
    pub viewport_mode: f32,
    pub _padding: [f32; 2],
}

/// GPU側に渡すビューポートユニフォーム（背景描画用、48バイト、16バイトアラインメント）
#[derive(Debug, Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
#[repr(C)]
pub struct ViewportUniforms {
    /// ビューポートサイズ [width, height]
    pub viewport_size: [f32; 2],
    /// キャンバスサイズ [width, height]
    pub canvas_size: [f32; 2],
    /// キャンバス左上のビューポート座標 [x, y]
    pub canvas_origin: [f32; 2],
    /// キャンバス表示サイズ（ズーム後）[width, height]
    pub canvas_display_size: [f32; 2],
    /// チェッカーボードタイルサイズ（スクリーンピクセル）
    pub checker_tile_size: f32,
    /// 16バイトアラインメント用パディング
    pub _padding: [f32; 3],
}

// =========================================================================
// 行列ユーティリティ
// =========================================================================

/// 4x4行列の乗算（列優先格納: result = a × b）
pub fn mul_mat4(a: [[f32; 4]; 4], b: [[f32; 4]; 4]) -> [[f32; 4]; 4] {
    let mut result = [[0.0f32; 4]; 4];
    for col in 0..4 {
        for row in 0..4 {
            result[col][row] = a[0][row] * b[col][0]
                + a[1][row] * b[col][1]
                + a[2][row] * b[col][2]
                + a[3][row] * b[col][3];
        }
    }
    result
}

/// キャンバスNDC → ビューポートNDC への変換行列を計算する（列優先）
pub fn canvas_to_viewport_matrix(vp: &ViewportParams, canvas_w: f32, canvas_h: f32) -> [[f32; 4]; 4] {
    let display_w = canvas_w * vp.zoom;
    let display_h = canvas_h * vp.zoom;

    // キャンバス中心のビューポートピクセル座標
    let center_x = vp.canvas_origin_x + display_w / 2.0;
    let center_y = vp.canvas_origin_y + display_h / 2.0;

    // ビューポートNDC空間でのキャンバス中心位置
    let tx = center_x / vp.viewport_width * 2.0 - 1.0;
    let ty = 1.0 - center_y / vp.viewport_height * 2.0;

    // キャンバスNDC空間のスケーリング
    let sx = display_w / vp.viewport_width;
    let sy = display_h / vp.viewport_height;

    [
        [sx, 0.0, 0.0, 0.0],
        [0.0, sy, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [tx, ty, 0.0, 1.0],
    ]
}

/// 4x4行列の逆行列を計算する（列優先格納）
/// 2D変換行列（回転+スケール+平行移動）専用の最適化版
pub fn invert_mat4(m: [[f32; 4]; 4]) -> [[f32; 4]; 4] {
    // 列優先: m[col][row]
    let a = m[0][0];
    let b = m[1][0];
    let c = m[0][1];
    let d = m[1][1];
    let tx = m[3][0];
    let ty = m[3][1];

    let det = a * d - b * c;
    if det.abs() < 1e-10 {
        // 退化行列の場合は単位行列を返す
        return [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0],
        ];
    }

    let inv_det = 1.0 / det;
    let ia = d * inv_det;
    let ib = -b * inv_det;
    let ic = -c * inv_det;
    let id = a * inv_det;

    [
        [ia, ic, 0.0, 0.0],
        [ib, id, 0.0, 0.0],
        [0.0, 0.0, 1.0, 0.0],
        [-(ia * tx + ib * ty), -(ic * tx + id * ty), 0.0, 1.0],
    ]
}
