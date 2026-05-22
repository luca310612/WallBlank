// Phase 7B: スパニング壁紙キャンバス
//
// Why: 複数ディスプレイをまたぐ 1 枚の仮想キャンバスとして扱い、各 DisplaySpan
//      の領域を切り出して個別 IOSurface に書き出す経路の土台となるデータ型を定義する。
//      Swift 側 `SpanningCanvasController` から JSON で渡し、`WgpuEngine` に保持させる。

use serde::{Deserialize, Serialize};

/// 1 ディスプレイぶんの span 情報
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplaySpan {
    /// CGDirectDisplayID 相当 (Swift から渡る u32)
    pub display_id: u32,
    /// 仮想キャンバス左上を (0, 0) としたときの origin
    pub origin: (i32, i32),
    /// このディスプレイがカバーする領域サイズ
    pub size: (u32, u32),
}

impl DisplaySpan {
    /// 仮想キャンバス内に完全に収まるか (clamping 対象判定用)
    pub fn fits_within(&self, canvas_width: u32, canvas_height: u32) -> bool {
        let (x, y) = self.origin;
        let (w, h) = self.size;
        if x < 0 || y < 0 {
            return false;
        }
        let right = (x as i64) + (w as i64);
        let bottom = (y as i64) + (h as i64);
        right <= canvas_width as i64 && bottom <= canvas_height as i64
    }
}

/// スパニング壁紙のキャンバス。
/// `displays` は描画順 (sort 済み) と仮定する。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SpanningCanvas {
    pub width: u32,
    pub height: u32,
    pub displays: Vec<DisplaySpan>,
}

impl Default for SpanningCanvas {
    fn default() -> Self {
        SpanningCanvas {
            width: 0,
            height: 0,
            displays: Vec::new(),
        }
    }
}

impl SpanningCanvas {
    /// 与えられた display_id の DisplaySpan を返す。
    pub fn span_for(&self, display_id: u32) -> Option<&DisplaySpan> {
        self.displays.iter().find(|s| s.display_id == display_id)
    }

    /// canvas の有効性を検査する。
    /// - width/height > 0
    /// - displays が空でない
    /// - 全 display が canvas 内に収まる
    pub fn validate(&self) -> Result<(), SpanningError> {
        if self.width == 0 || self.height == 0 {
            return Err(SpanningError::EmptyCanvas);
        }
        if self.displays.is_empty() {
            return Err(SpanningError::NoDisplays);
        }
        for span in &self.displays {
            if !span.fits_within(self.width, self.height) {
                return Err(SpanningError::DisplayOutOfBounds {
                    display_id: span.display_id,
                });
            }
            if span.size.0 == 0 || span.size.1 == 0 {
                return Err(SpanningError::ZeroSizedDisplay {
                    display_id: span.display_id,
                });
            }
        }
        Ok(())
    }

    /// JSON 文字列からデコードする (FFI 経由用)
    pub fn from_json(json: &str) -> Result<Self, SpanningError> {
        serde_json::from_str(json).map_err(|e| SpanningError::Decode(e.to_string()))
    }

    /// JSON へエンコードする (デバッグ/UI 表示用)
    pub fn to_json(&self) -> Result<String, SpanningError> {
        serde_json::to_string(self).map_err(|e| SpanningError::Encode(e.to_string()))
    }

    /// union 矩形からキャンバスを構築するヘルパ
    /// Why: Swift 側で各 NSScreen.frame を渡すだけで、自動で origin を 0,0 寄せできる。
    pub fn from_screen_rects(rects: &[(u32, i32, i32, u32, u32)]) -> Self {
        // tuple: (display_id, x, y, w, h) — y は macOS の通常座標系 (下方向)
        if rects.is_empty() {
            return SpanningCanvas::default();
        }
        let min_x = rects.iter().map(|r| r.1).min().unwrap_or(0);
        let min_y = rects.iter().map(|r| r.2).min().unwrap_or(0);
        let max_x = rects.iter().map(|r| r.1 + r.3 as i32).max().unwrap_or(0);
        let max_y = rects.iter().map(|r| r.2 + r.4 as i32).max().unwrap_or(0);
        let width = (max_x - min_x).max(0) as u32;
        let height = (max_y - min_y).max(0) as u32;
        let displays = rects
            .iter()
            .map(|&(id, x, y, w, h)| DisplaySpan {
                display_id: id,
                origin: (x - min_x, y - min_y),
                size: (w, h),
            })
            .collect();
        SpanningCanvas {
            width,
            height,
            displays,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SpanningError {
    EmptyCanvas,
    NoDisplays,
    DisplayOutOfBounds { display_id: u32 },
    ZeroSizedDisplay { display_id: u32 },
    Decode(String),
    Encode(String),
}

impl std::fmt::Display for SpanningError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SpanningError::EmptyCanvas => write!(f, "spanning: canvas size is zero"),
            SpanningError::NoDisplays => write!(f, "spanning: no displays"),
            SpanningError::DisplayOutOfBounds { display_id } => {
                write!(f, "spanning: display {} out of canvas bounds", display_id)
            }
            SpanningError::ZeroSizedDisplay { display_id } => {
                write!(f, "spanning: display {} has zero size", display_id)
            }
            SpanningError::Decode(msg) => write!(f, "spanning: decode failed: {}", msg),
            SpanningError::Encode(msg) => write!(f, "spanning: encode failed: {}", msg),
        }
    }
}

impl std::error::Error for SpanningError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_empty() {
        let c = SpanningCanvas::default();
        assert_eq!(c.width, 0);
        assert!(c.displays.is_empty());
    }

    #[test]
    fn validate_rejects_zero_canvas() {
        let c = SpanningCanvas {
            width: 0,
            height: 100,
            displays: vec![],
        };
        assert_eq!(c.validate(), Err(SpanningError::EmptyCanvas));
    }

    #[test]
    fn validate_rejects_no_displays() {
        let c = SpanningCanvas {
            width: 100,
            height: 100,
            displays: vec![],
        };
        assert_eq!(c.validate(), Err(SpanningError::NoDisplays));
    }

    #[test]
    fn validate_rejects_out_of_bounds() {
        let c = SpanningCanvas {
            width: 100,
            height: 100,
            displays: vec![DisplaySpan {
                display_id: 1,
                origin: (50, 50),
                size: (200, 200),
            }],
        };
        assert_eq!(
            c.validate(),
            Err(SpanningError::DisplayOutOfBounds { display_id: 1 })
        );
    }

    #[test]
    fn validate_rejects_zero_size_display() {
        let c = SpanningCanvas {
            width: 100,
            height: 100,
            displays: vec![DisplaySpan {
                display_id: 9,
                origin: (0, 0),
                size: (0, 50),
            }],
        };
        assert_eq!(
            c.validate(),
            Err(SpanningError::ZeroSizedDisplay { display_id: 9 })
        );
    }

    #[test]
    fn validate_passes_for_valid_setup() {
        let c = SpanningCanvas {
            width: 4000,
            height: 1080,
            displays: vec![
                DisplaySpan {
                    display_id: 1,
                    origin: (0, 0),
                    size: (1920, 1080),
                },
                DisplaySpan {
                    display_id: 2,
                    origin: (1920, 0),
                    size: (1920, 1080),
                },
            ],
        };
        assert!(c.validate().is_ok());
    }

    #[test]
    fn span_for_returns_match() {
        let c = SpanningCanvas {
            width: 100,
            height: 100,
            displays: vec![
                DisplaySpan {
                    display_id: 1,
                    origin: (0, 0),
                    size: (50, 100),
                },
                DisplaySpan {
                    display_id: 2,
                    origin: (50, 0),
                    size: (50, 100),
                },
            ],
        };
        assert_eq!(c.span_for(2).unwrap().origin, (50, 0));
        assert!(c.span_for(99).is_none());
    }

    #[test]
    fn json_roundtrip_preserves_structure() {
        let original = SpanningCanvas {
            width: 3840,
            height: 1080,
            displays: vec![DisplaySpan {
                display_id: 17,
                origin: (1920, 0),
                size: (1920, 1080),
            }],
        };
        let json = original.to_json().unwrap();
        let back = SpanningCanvas::from_json(&json).unwrap();
        assert_eq!(original, back);
    }

    #[test]
    fn from_json_invalid_returns_error() {
        let result = SpanningCanvas::from_json("not json {{");
        assert!(matches!(result, Err(SpanningError::Decode(_))));
    }

    #[test]
    fn from_screen_rects_normalizes_origin() {
        // 左に -1920 から始まる外部ディスプレイと内蔵ディスプレイ
        let canvas = SpanningCanvas::from_screen_rects(&[
            (1, -1920, 0, 1920, 1080),
            (2, 0, 0, 1920, 1080),
        ]);
        assert_eq!(canvas.width, 3840);
        assert_eq!(canvas.height, 1080);
        // 左端だった display 1 は (0, 0) に寄る
        assert_eq!(canvas.span_for(1).unwrap().origin, (0, 0));
        assert_eq!(canvas.span_for(2).unwrap().origin, (1920, 0));
    }

    #[test]
    fn from_screen_rects_empty_returns_default() {
        let canvas = SpanningCanvas::from_screen_rects(&[]);
        assert_eq!(canvas, SpanningCanvas::default());
    }
}
