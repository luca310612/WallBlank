// DDSテクスチャフォーマットデコーダー

use thiserror::Error;

#[derive(Error, Debug)]
pub enum DdsError {
    #[error("DDSデータが小さすぎます")]
    TooSmall,
    #[error("不正なDDS寸法: {0}x{1}")]
    InvalidDimensions(u32, u32),
    #[error("サポートされていないDDSフォーマット (FourCC: {0})")]
    UnsupportedFormat(String),
    #[error("DDSデータ不足")]
    InsufficientData,
}

/// DDSヘッダー情報
struct DdsHeader {
    width: u32,
    height: u32,
    pf_flags: u32,
    four_cc: u32,
    rgb_bit_count: u32,
    r_bit_mask: u32,
    g_bit_mask: u32,
    b_bit_mask: u32,
    a_bit_mask: u32,
}

// FourCC定数
const DXT1: u32 = 0x31545844;
const DXT3: u32 = 0x33545844;
const DXT5: u32 = 0x35545844;
const DDPF_RGB: u32 = 0x40;

/// DDSデコーダー
pub struct DdsDecoder;

impl DdsDecoder {
    /// DDSバイナリデータをRGBAピクセルにデコードする
    /// 戻り値: (width, height, rgba_pixels)
    pub fn decode(data: &[u8]) -> Result<(u32, u32, Vec<u8>), DdsError> {
        if data.len() < 128 {
            return Err(DdsError::TooSmall);
        }

        let header = parse_header(data);
        let width = header.width;
        let height = header.height;

        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return Err(DdsError::InvalidDimensions(width, height));
        }

        let texture_data = &data[128..];
        let four_cc = header.four_cc;

        let pixels = if four_cc == DXT1 {
            decode_dxt1(texture_data, width, height)?
        } else if four_cc == DXT3 {
            decode_dxt3(texture_data, width, height)?
        } else if four_cc == DXT5 {
            decode_dxt5(texture_data, width, height)?
        } else if header.pf_flags & DDPF_RGB != 0 {
            decode_uncompressed(texture_data, width, height, &header)?
        } else {
            return Err(DdsError::UnsupportedFormat(four_cc_to_string(four_cc)));
        };

        Ok((width, height, pixels))
    }
}

fn read_u16_le(data: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([data[offset], data[offset + 1]])
}

fn read_u32_le(data: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
}

fn parse_header(data: &[u8]) -> DdsHeader {
    DdsHeader {
        width: read_u32_le(data, 16),
        height: read_u32_le(data, 12),
        pf_flags: read_u32_le(data, 80),
        four_cc: read_u32_le(data, 84),
        rgb_bit_count: read_u32_le(data, 88),
        r_bit_mask: read_u32_le(data, 92),
        g_bit_mask: read_u32_le(data, 96),
        b_bit_mask: read_u32_le(data, 100),
        a_bit_mask: read_u32_le(data, 104),
    }
}

fn four_cc_to_string(four_cc: u32) -> String {
    (0..4)
        .map(|i| {
            let byte = ((four_cc >> (i * 8)) & 0xFF) as u8;
            if (32..127).contains(&byte) {
                byte as char
            } else {
                '?'
            }
        })
        .collect()
}

/// RGB565カラーをRGBA8に展開
fn decode_color_block(c0: u16, c1: u16, is_dxt1: bool) -> [(u8, u8, u8, u8); 4] {
    let r0 = (((c0 >> 11) & 0x1F) as u32 * 255 / 31) as u8;
    let g0 = (((c0 >> 5) & 0x3F) as u32 * 255 / 63) as u8;
    let b0 = ((c0 & 0x1F) as u32 * 255 / 31) as u8;

    let r1 = (((c1 >> 11) & 0x1F) as u32 * 255 / 31) as u8;
    let g1 = (((c1 >> 5) & 0x3F) as u32 * 255 / 63) as u8;
    let b1 = ((c1 & 0x1F) as u32 * 255 / 31) as u8;

    let mut colors = [
        (r0, g0, b0, 255u8),
        (r1, g1, b1, 255u8),
        (0, 0, 0, 255),
        (0, 0, 0, 255),
    ];

    if is_dxt1 && c0 <= c1 {
        colors[2] = (
            ((r0 as u16 + r1 as u16) / 2) as u8,
            ((g0 as u16 + g1 as u16) / 2) as u8,
            ((b0 as u16 + b1 as u16) / 2) as u8,
            255,
        );
        colors[3] = (0, 0, 0, 0); // 透明
    } else {
        colors[2] = (
            ((r0 as u16 * 2 + r1 as u16) / 3) as u8,
            ((g0 as u16 * 2 + g1 as u16) / 3) as u8,
            ((b0 as u16 * 2 + b1 as u16) / 3) as u8,
            255,
        );
        colors[3] = (
            ((r0 as u16 + r1 as u16 * 2) / 3) as u8,
            ((g0 as u16 + g1 as u16 * 2) / 3) as u8,
            ((b0 as u16 + b1 as u16 * 2) / 3) as u8,
            255,
        );
    }

    colors
}

fn decode_alpha_table(a0: u8, a1: u8) -> [u8; 8] {
    let mut table = [0u8; 8];
    table[0] = a0;
    table[1] = a1;

    let (a0, a1) = (a0 as u16, a1 as u16);
    if a0 > a1 {
        table[2] = ((6 * a0 + 1 * a1) / 7) as u8;
        table[3] = ((5 * a0 + 2 * a1) / 7) as u8;
        table[4] = ((4 * a0 + 3 * a1) / 7) as u8;
        table[5] = ((3 * a0 + 4 * a1) / 7) as u8;
        table[6] = ((2 * a0 + 5 * a1) / 7) as u8;
        table[7] = ((1 * a0 + 6 * a1) / 7) as u8;
    } else {
        table[2] = ((4 * a0 + 1 * a1) / 5) as u8;
        table[3] = ((3 * a0 + 2 * a1) / 5) as u8;
        table[4] = ((2 * a0 + 3 * a1) / 5) as u8;
        table[5] = ((1 * a0 + 4 * a1) / 5) as u8;
        table[6] = 0;
        table[7] = 255;
    }
    table
}

/// ブロック内のピクセルを書き込むヘルパー
#[inline]
fn write_pixel(pixels: &mut [u8], x: usize, y: usize, width: usize, r: u8, g: u8, b: u8, a: u8) {
    let idx = (y * width + x) * 4;
    pixels[idx] = r;
    pixels[idx + 1] = g;
    pixels[idx + 2] = b;
    pixels[idx + 3] = a;
}

fn decode_dxt1(data: &[u8], width: u32, height: u32) -> Result<Vec<u8>, DdsError> {
    let (w, h) = (width as usize, height as usize);
    let mut pixels = vec![255u8; w * h * 4];
    let blocks_x = (w + 3) / 4;
    let blocks_y = (h + 3) / 4;
    let mut offset = 0;

    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            if offset + 8 > data.len() {
                return Ok(pixels); // データ不足は部分デコードで許容
            }

            let c0 = read_u16_le(data, offset);
            let c1 = read_u16_le(data, offset + 2);
            let indices = read_u32_le(data, offset + 4);
            offset += 8;

            let colors = decode_color_block(c0, c1, true);

            for py in 0..4 {
                for px in 0..4 {
                    let x = bx * 4 + px;
                    let y = by * 4 + py;
                    if x < w && y < h {
                        let idx = ((indices >> ((py * 4 + px) * 2)) & 0x3) as usize;
                        let c = colors[idx];
                        write_pixel(&mut pixels, x, y, w, c.0, c.1, c.2, c.3);
                    }
                }
            }
        }
    }
    Ok(pixels)
}

fn decode_dxt3(data: &[u8], width: u32, height: u32) -> Result<Vec<u8>, DdsError> {
    let (w, h) = (width as usize, height as usize);
    let mut pixels = vec![255u8; w * h * 4];
    let blocks_x = (w + 3) / 4;
    let blocks_y = (h + 3) / 4;
    let mut offset = 0;

    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            if offset + 16 > data.len() {
                return Ok(pixels);
            }

            // 8バイトのアルファデータ
            let mut alphas = [255u8; 16];
            for i in 0..8 {
                let byte = data[offset + i];
                alphas[i * 2] = (byte & 0x0F) * 17;
                alphas[i * 2 + 1] = (byte >> 4) * 17;
            }
            offset += 8;

            let c0 = read_u16_le(data, offset);
            let c1 = read_u16_le(data, offset + 2);
            let indices = read_u32_le(data, offset + 4);
            offset += 8;

            let colors = decode_color_block(c0, c1, false);

            for py in 0..4 {
                for px in 0..4 {
                    let x = bx * 4 + px;
                    let y = by * 4 + py;
                    if x < w && y < h {
                        let idx = ((indices >> ((py * 4 + px) * 2)) & 0x3) as usize;
                        let c = colors[idx];
                        let a = alphas[py * 4 + px];
                        write_pixel(&mut pixels, x, y, w, c.0, c.1, c.2, a);
                    }
                }
            }
        }
    }
    Ok(pixels)
}

fn decode_dxt5(data: &[u8], width: u32, height: u32) -> Result<Vec<u8>, DdsError> {
    let (w, h) = (width as usize, height as usize);
    let mut pixels = vec![255u8; w * h * 4];
    let blocks_x = (w + 3) / 4;
    let blocks_y = (h + 3) / 4;
    let mut offset = 0;

    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            if offset + 16 > data.len() {
                return Ok(pixels);
            }

            // アルファブロック
            let a0 = data[offset];
            let a1 = data[offset + 1];

            let mut alpha_indices: u64 = 0;
            for i in 0..6 {
                alpha_indices |= (data[offset + 2 + i] as u64) << (i * 8);
            }
            offset += 8;

            let alpha_table = decode_alpha_table(a0, a1);

            let c0 = read_u16_le(data, offset);
            let c1 = read_u16_le(data, offset + 2);
            let indices = read_u32_le(data, offset + 4);
            offset += 8;

            let colors = decode_color_block(c0, c1, false);

            for py in 0..4 {
                for px in 0..4 {
                    let x = bx * 4 + px;
                    let y = by * 4 + py;
                    if x < w && y < h {
                        let color_idx = ((indices >> ((py * 4 + px) * 2)) & 0x3) as usize;
                        let alpha_idx = ((alpha_indices >> ((py * 4 + px) * 3)) & 0x7) as usize;
                        let c = colors[color_idx];
                        let a = alpha_table[alpha_idx];
                        write_pixel(&mut pixels, x, y, w, c.0, c.1, c.2, a);
                    }
                }
            }
        }
    }
    Ok(pixels)
}

fn decode_uncompressed(
    data: &[u8],
    width: u32,
    height: u32,
    header: &DdsHeader,
) -> Result<Vec<u8>, DdsError> {
    let (w, h) = (width as usize, height as usize);
    let mut pixels = vec![255u8; w * h * 4];
    let bytes_per_pixel = header.rgb_bit_count as usize / 8;

    let r_mask = header.r_bit_mask;
    let g_mask = header.g_bit_mask;
    let b_mask = header.b_bit_mask;
    let a_mask = header.a_bit_mask;

    let r_shift = if r_mask == 0 { 0 } else { r_mask.trailing_zeros() };
    let g_shift = if g_mask == 0 { 0 } else { g_mask.trailing_zeros() };
    let b_shift = if b_mask == 0 { 0 } else { b_mask.trailing_zeros() };
    let a_shift = if a_mask == 0 { 0 } else { a_mask.trailing_zeros() };

    let r_max = if r_mask == 0 { 1.0 } else { (r_mask >> r_shift) as f32 };
    let g_max = if g_mask == 0 { 1.0 } else { (g_mask >> g_shift) as f32 };
    let b_max = if b_mask == 0 { 1.0 } else { (b_mask >> b_shift) as f32 };
    let a_max = if a_mask == 0 { 1.0 } else { (a_mask >> a_shift) as f32 };

    for y in 0..h {
        for x in 0..w {
            let src_idx = (y * w + x) * bytes_per_pixel;
            if src_idx + bytes_per_pixel > data.len() {
                continue;
            }

            let mut pixel: u32 = 0;
            for i in 0..bytes_per_pixel {
                pixel |= (data[src_idx + i] as u32) << (i * 8);
            }

            let dst_idx = (y * w + x) * 4;
            pixels[dst_idx] = (((pixel & r_mask) >> r_shift) as f32 / r_max * 255.0) as u8;
            pixels[dst_idx + 1] = (((pixel & g_mask) >> g_shift) as f32 / g_max * 255.0) as u8;
            pixels[dst_idx + 2] = (((pixel & b_mask) >> b_shift) as f32 / b_max * 255.0) as u8;
            pixels[dst_idx + 3] = if a_mask == 0 {
                255
            } else {
                (((pixel & a_mask) >> a_shift) as f32 / a_max * 255.0) as u8
            };
        }
    }
    Ok(pixels)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_color_block() {
        let colors = decode_color_block(0xFFFF, 0x0000, false);
        assert_eq!(colors[0], (255, 255, 255, 255));
        assert_eq!(colors[1], (0, 0, 0, 255));
    }

    #[test]
    fn test_decode_alpha_table_greater() {
        let table = decode_alpha_table(200, 50);
        assert_eq!(table[0], 200);
        assert_eq!(table[1], 50);
        // 中間値が正しく補間されること
        assert!(table[2] > table[3]);
    }

    #[test]
    fn test_decode_alpha_table_less_or_equal() {
        let table = decode_alpha_table(50, 200);
        assert_eq!(table[0], 50);
        assert_eq!(table[1], 200);
        assert_eq!(table[6], 0);
        assert_eq!(table[7], 255);
    }

    #[test]
    fn test_four_cc_to_string() {
        assert_eq!(four_cc_to_string(DXT1), "DXT1");
        assert_eq!(four_cc_to_string(DXT5), "DXT5");
    }
}
