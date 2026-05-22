use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// 認証プロバイダー
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuthProvider {
    Anonymous,
    Email,
    Google,
}

/// SNSリンク情報
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SocialLinks {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub twitter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instagram: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pixiv: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub youtube: Option<String>,
}

impl SocialLinks {
    /// 設定されているリンクが1つ以上あるか
    pub fn has_any_link(&self) -> bool {
        [&self.twitter, &self.instagram, &self.pixiv, &self.youtube]
            .iter()
            .any(|link| link.as_ref().is_some_and(|s| !s.is_empty()))
    }

    /// 全リンクのバリデーション
    pub fn is_all_links_valid(&self) -> bool {
        let checks = [
            (&self.twitter, "https://x.com/"),
            (&self.instagram, "https://www.instagram.com/"),
            (&self.pixiv, "https://www.pixiv.net/users/"),
            (&self.youtube, "https://www.youtube.com/"),
        ];

        checks.iter().all(|(link, prefix)| {
            match link {
                Some(value) if !value.is_empty() => value.starts_with(prefix),
                _ => true,
            }
        })
    }
}

/// 同期設定
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncPreferences {
    #[serde(default = "default_true")]
    pub sync_collections: bool,
    #[serde(default = "default_true")]
    pub sync_schedules: bool,
    #[serde(default = "default_true")]
    pub sync_environment_rules: bool,
    #[serde(default = "default_true")]
    pub sync_settings: bool,
}

fn default_true() -> bool {
    true
}

impl Default for SyncPreferences {
    fn default() -> Self {
        Self {
            sync_collections: true,
            sync_schedules: true,
            sync_environment_rules: true,
            sync_settings: true,
        }
    }
}

/// ユーザープロフィール
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserProfile {
    pub uid: String,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(rename = "photoURL", skip_serializing_if = "Option::is_none")]
    pub photo_url: Option<String>,
    pub auth_provider: AuthProvider,
    pub created_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_sync_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub is_admin: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_avatar_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bio: Option<String>,
    #[serde(default)]
    pub social_links: SocialLinks,
    #[serde(default)]
    pub sync_preferences: SyncPreferences,
}

impl UserProfile {
    /// デフォルト初期化
    pub fn create(uid: String, display_name: Option<String>, auth_provider: AuthProvider) -> Self {
        Self {
            uid,
            display_name: display_name.unwrap_or_else(|| "ユーザー".to_string()),
            email: None,
            photo_url: None,
            auth_provider,
            created_at: Utc::now(),
            last_sync_at: None,
            is_admin: false,
            custom_avatar_path: None,
            bio: None,
            social_links: SocialLinks::default(),
            sync_preferences: SyncPreferences::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_social_links_validation() {
        let valid = SocialLinks {
            twitter: Some("https://x.com/user".to_string()),
            instagram: None,
            pixiv: Some("https://www.pixiv.net/users/12345".to_string()),
            youtube: None,
        };
        assert!(valid.is_all_links_valid());
        assert!(valid.has_any_link());

        let invalid = SocialLinks {
            twitter: Some("https://twitter.com/user".to_string()),
            ..Default::default()
        };
        assert!(!invalid.is_all_links_valid());
    }

    #[test]
    fn test_user_profile_json_roundtrip() {
        let profile = UserProfile::create(
            "uid123".to_string(),
            Some("テストユーザー".to_string()),
            AuthProvider::Google,
        );
        let json = serde_json::to_string(&profile).unwrap();
        let decoded: UserProfile = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.uid, "uid123");
        assert_eq!(decoded.display_name, "テストユーザー");
    }
}
