use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// 壁紙コレクション（お気に入り・ユーザー定義）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperCollection {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub wallpaper_ids: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub modified_at: DateTime<Utc>,
    pub is_system: bool,
}

impl WallpaperCollection {
    pub fn new(name: String) -> Self {
        let now = Utc::now();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            icon: "folder".to_string(),
            wallpaper_ids: Vec::new(),
            created_at: now,
            modified_at: now,
            is_system: false,
        }
    }

    /// お気に入りコレクション（システム定義）
    pub fn favorites() -> Self {
        let now = Utc::now();
        Self {
            id: "favorites".to_string(),
            name: "お気に入り".to_string(),
            icon: "heart.fill".to_string(),
            wallpaper_ids: Vec::new(),
            created_at: now,
            modified_at: now,
            is_system: true,
        }
    }
}
