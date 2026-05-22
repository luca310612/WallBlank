# WallBlank

**WallBlank** という macOS 壁紙アプリ (SwiftUI + Metal + Rust) のソースコード公開版です。

このリポジトリは **コードを読むためのスナップショット** であり、そのままビルド・実行することはできません。`.xcodeproj` / `.xcworkspace` / Assets / `Info.plist` / `GoogleService-Info.plist` などの設定・リソースファイルは含まれていません。本番のビルド可能なソースツリーは別途プライベートに管理されています。

## 何が入っているか

- `WallpaperHub/` — メインアプリ (Swift / Metal)
- `WallpaperHubWidget/` — ウィジェット Extension (Swift)
- `ArtiaScreenSaver/` — スクリーンセーバー Extension (Swift)
- `Shared/` — 共有コード (Swift)
- `rust-core/` — コアロジック / Firebase REST クライアント / WGPU レンダラ (Rust Cargo workspace)

## アーキテクチャ概要

- **UI**: SwiftUI ベースの macOS アプリ
- **レンダリング**: Metal シェーダ (`*.metal`) と WGPU (Rust 側 `artia-wgpu`)
- **コアロジック**: Rust の `artia-core` (壁紙ライブラリ / スケジュール / エフェクト / イベントバス / 設定)
- **クラウド連携**: Rust の `artia-firebase` (Firebase Auth / Firestore / Storage / Messaging の REST 実装)
- **Swift ↔ Rust 連携**: C FFI (`artia-ffi` が cbindgen で `artia_ffi.h` を生成し、Swift Bridging Header 経由で呼び出し)

詳しくは各ディレクトリのソースを参照してください。

## ライセンス

著作権はオーナーに帰属します。読み物としての公開のみを意図しており、商用利用 / 派生物の配布 / 再アップロードは許可されません。
