// Phase 6A: Audio Reactive uniform.
// Why: Swift 側で計算した FFT 周波数バンドを GPU シェーダ / particle simulation から参照可能にする。
//      Phase 4A 同様、descriptor 保管 + WGSL 同梱 + uniform 更新までを範囲とし、
//      実 GPU bind は後続フェーズで dispatch を有効化する。

use serde::{Deserialize, Serialize};

mod shader {
    pub const AUDIO_WGSL: &str = include_str!("shaders/audio/audio.wgsl");
}

pub use shader::AUDIO_WGSL;

/// 周波数バンドの最大数。
/// Why: WGSL uniform は 16 byte align を求めるため、`vec4<f32>` 32 個分 = 128 要素を確保する。
pub const MAX_AUDIO_BANDS: usize = 128;

/// シェーダから参照される audio uniform。
/// レイアウトは WGSL `Audio` struct と一致させる。
/// `bands[*]` は 0..1 の正規化済み振幅を想定する (Swift 側で normalize)。
#[derive(Clone, Debug, PartialEq)]
pub struct AudioUniform {
    pub bands: [f32; MAX_AUDIO_BANDS],
    /// 経過時間 (秒)。シェーダ側で位相利用。
    pub time: f32,
    /// 直近の bass / mid / treble 平均 (UI / particle binding の便宜)。
    pub bass: f32,
    pub mid: f32,
    pub treble: f32,
    /// 有効バンド数 (実際に書き込んだ要素数)。
    pub active_bands: u32,
}

impl Default for AudioUniform {
    fn default() -> Self {
        Self {
            bands: [0.0; MAX_AUDIO_BANDS],
            time: 0.0,
            bass: 0.0,
            mid: 0.0,
            treble: 0.0,
            active_bands: 0,
        }
    }
}

impl AudioUniform {
    /// 0..MAX_AUDIO_BANDS-1 のバンド値を取得 (範囲外は 0)。
    pub fn band(&self, index: usize) -> f32 {
        if index < MAX_AUDIO_BANDS {
            self.bands[index]
        } else {
            0.0
        }
    }

    /// Swift 側から渡された配列で uniform を更新する。
    /// - `incoming.len()` が MAX より小さければ残りは 0 で埋める。
    /// - `incoming.len()` が MAX より大きければ先頭 MAX 個のみ採用。
    /// - bass / mid / treble は単純な 3 分割平均。
    pub fn update(&mut self, incoming: &[f32], time: f32) {
        // バンド書き込み
        let n = incoming.len().min(MAX_AUDIO_BANDS);
        for i in 0..n {
            self.bands[i] = incoming[i];
        }
        for i in n..MAX_AUDIO_BANDS {
            self.bands[i] = 0.0;
        }
        self.time = time;
        self.active_bands = n as u32;

        // 3 分割平均 (低域 / 中域 / 高域) を bass/mid/treble に保持。
        // 0 件のときは 0。
        if n == 0 {
            self.bass = 0.0;
            self.mid = 0.0;
            self.treble = 0.0;
            return;
        }
        let third = (n + 2) / 3; // round up so 1 件でも bass に入る
        let band_avg = |start: usize, end: usize| -> f32 {
            if start >= end {
                return 0.0;
            }
            let sum: f32 = self.bands[start..end].iter().sum();
            sum / (end - start) as f32
        };
        self.bass = band_avg(0, third.min(n));
        self.mid = band_avg(third.min(n), (2 * third).min(n));
        self.treble = band_avg((2 * third).min(n), n);
    }
}

/// Audio binding: emitter / shader が「どのバンドを参照するか」を指定するための Codable 値。
/// Swift `EmitterAudioBinding` と JSON 互換。
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct EmitterAudioBinding {
    /// 参照する band index (0..127)。範囲外は無効化扱い。
    pub band_index: u32,
    /// バンド値に乗じる倍率。
    pub scale: f32,
}

impl Default for EmitterAudioBinding {
    fn default() -> Self {
        Self {
            band_index: 0,
            scale: 0.0,
        }
    }
}

impl EmitterAudioBinding {
    /// `base_rate + audio.bands[band_index] * scale` を返す。
    pub fn modulated_rate(&self, base_rate: f32, audio: &AudioUniform) -> f32 {
        let v = audio.band(self.band_index as usize);
        // バンド値は 0..1 想定だが念のため floor 0 でガード。
        let v = if v.is_finite() && v >= 0.0 { v } else { 0.0 };
        base_rate + v * self.scale
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_audio_uniform_is_all_zeros() {
        let u = AudioUniform::default();
        assert_eq!(u.bass, 0.0);
        assert_eq!(u.mid, 0.0);
        assert_eq!(u.treble, 0.0);
        assert_eq!(u.active_bands, 0);
        for v in u.bands.iter() {
            assert_eq!(*v, 0.0);
        }
    }

    #[test]
    fn update_writes_bands_and_zero_pads() {
        let mut u = AudioUniform::default();
        u.update(&[0.1, 0.2, 0.3], 1.5);
        assert_eq!(u.bands[0], 0.1);
        assert_eq!(u.bands[1], 0.2);
        assert_eq!(u.bands[2], 0.3);
        assert_eq!(u.bands[3], 0.0);
        assert_eq!(u.time, 1.5);
        assert_eq!(u.active_bands, 3);
    }

    #[test]
    fn update_truncates_above_max() {
        let mut u = AudioUniform::default();
        let big = vec![0.5; MAX_AUDIO_BANDS + 16];
        u.update(&big, 0.0);
        assert_eq!(u.active_bands, MAX_AUDIO_BANDS as u32);
        assert_eq!(u.bands[MAX_AUDIO_BANDS - 1], 0.5);
    }

    #[test]
    fn bass_mid_treble_split_by_thirds() {
        let mut u = AudioUniform::default();
        // 6 本: bass(0..2)=1.0, mid(2..4)=0.0, treble(4..6)=1.0
        u.update(&[1.0, 1.0, 0.0, 0.0, 1.0, 1.0], 0.0);
        assert!((u.bass - 1.0).abs() < 1e-6);
        assert!(u.mid.abs() < 1e-6);
        assert!((u.treble - 1.0).abs() < 1e-6);
    }

    #[test]
    fn band_returns_zero_when_out_of_range() {
        let mut u = AudioUniform::default();
        u.update(&[0.7], 0.0);
        assert_eq!(u.band(0), 0.7);
        assert_eq!(u.band(MAX_AUDIO_BANDS), 0.0);
        assert_eq!(u.band(99999), 0.0);
    }

    #[test]
    fn emitter_audio_binding_modulates_base_rate() {
        let mut u = AudioUniform::default();
        u.update(&[0.0, 0.5, 0.0, 0.0], 0.0);
        let bind = EmitterAudioBinding {
            band_index: 1,
            scale: 100.0,
        };
        assert!((bind.modulated_rate(10.0, &u) - 60.0).abs() < 1e-4);
    }

    #[test]
    fn emitter_audio_binding_rejects_invalid_band() {
        let bind = EmitterAudioBinding {
            band_index: 9999,
            scale: 50.0,
        };
        let u = AudioUniform::default();
        assert_eq!(bind.modulated_rate(7.0, &u), 7.0);
    }

    #[test]
    fn shader_constant_is_loaded() {
        assert!(AUDIO_WGSL.contains("Audio"));
    }
}
