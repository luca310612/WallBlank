use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::wallpaper::WallpaperType;

/// オンラインギャラリーの壁紙アイテム
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GalleryItem {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub wallpaper_type: WallpaperType,
    pub category: String,
    pub tags: Vec<String>,
    pub author_name: String,
    #[serde(rename = "authorID")]
    pub author_id: String,
    #[serde(rename = "thumbnailURLString")]
    pub thumbnail_url_string: String,
    #[serde(rename = "fileURLString")]
    pub file_url_string: String,
    pub file_size: i64,
    pub width: i32,
    pub height: i32,
    pub download_count: i32,
    pub like_count: i32,
    pub created_at: DateTime<Utc>,
    pub is_approved: bool,
    pub is_downloaded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_extension: Option<String>,
}
