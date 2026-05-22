use serde::{Deserialize, Serialize};

/// アクティブ時間帯
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveHours {
    pub start_hour: u32,
    pub start_minute: u32,
    pub end_hour: u32,
    pub end_minute: u32,
}

impl ActiveHours {
    /// 指定された時刻がアクティブ時間内かどうか判定
    pub fn is_active_at(&self, hour: u32, minute: u32) -> bool {
        let current = hour * 60 + minute;
        let start = self.start_hour * 60 + self.start_minute;
        let end = self.end_hour * 60 + self.end_minute;

        if start <= end {
            current >= start && current < end
        } else {
            // 深夜をまたぐ場合（例: 22:00 - 06:00）
            current >= start || current < end
        }
    }
}

/// 壁紙ローテーションスケジュール
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WallpaperSchedule {
    pub id: String,
    pub name: String,
    pub is_enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collection_id: Option<String>,
    pub wallpaper_ids: Vec<String>,
    /// ローテーション間隔（秒）
    pub interval: f64,
    pub shuffle_order: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_hours: Option<ActiveHours>,
}

impl WallpaperSchedule {
    pub fn new(name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            is_enabled: true,
            collection_id: None,
            wallpaper_ids: Vec::new(),
            interval: 1800.0, // 30分
            shuffle_order: false,
            display_ids: None,
            active_hours: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_active_hours_normal() {
        let hours = ActiveHours {
            start_hour: 9,
            start_minute: 0,
            end_hour: 17,
            end_minute: 0,
        };
        assert!(hours.is_active_at(12, 0));
        assert!(!hours.is_active_at(8, 0));
        assert!(!hours.is_active_at(17, 0));
    }

    #[test]
    fn test_active_hours_overnight() {
        let hours = ActiveHours {
            start_hour: 22,
            start_minute: 0,
            end_hour: 6,
            end_minute: 0,
        };
        assert!(hours.is_active_at(23, 0));
        assert!(hours.is_active_at(3, 0));
        assert!(!hours.is_active_at(12, 0));
    }
}
