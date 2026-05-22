use serde::{Deserialize, Serialize};

/// 壁紙アイテムの種類
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WallpaperType {
    Image,
    Video,
    Gif,
    Shader,
    Scene,
}

impl WallpaperType {
    /// 日本語表示名
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Image => "画像",
            Self::Video => "動画",
            Self::Gif => "GIF",
            Self::Shader => "シェーダー",
            Self::Scene => "シーン",
        }
    }

    /// SF Symbolアイコン名
    pub fn icon(&self) -> &'static str {
        match self {
            Self::Image => "photo",
            Self::Video => "play.rectangle",
            Self::Gif => "photo.stack",
            Self::Shader => "wand.and.stars",
            Self::Scene => "cube",
        }
    }
}

/// 壁紙アイテムのデータモデル
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperItem {
    pub id: String,
    pub name: String,
    #[serde(rename = "type")]
    pub wallpaper_type: WallpaperType,
    pub thumbnail_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shader_type: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder_name: Option<String>,
    pub category: String,
    pub is_downloaded: bool,
    pub tags: Vec<String>,
}

impl WallpaperItem {
    pub fn new(
        name: String,
        wallpaper_type: WallpaperType,
        thumbnail_name: String,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            wallpaper_type,
            thumbnail_name,
            file_name: None,
            shader_type: None,
            folder_name: None,
            category: "General".to_string(),
            is_downloaded: false,
            tags: Vec::new(),
        }
    }
}
