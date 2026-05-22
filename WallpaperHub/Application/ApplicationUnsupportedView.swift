import SwiftUI

// MARK: - ApplicationUnsupportedView

/// Phase 3C: `.app` を Application 壁紙としてドロップした際に表示する未対応説明ビュー。
/// Why: macOS は SIP / Mission Control の制約から、任意 .app をデスクトップウィンドウ層へ
///      固定する API を提供していない。仕様の誤魔化しを避け、ユーザーに明示する。
struct ApplicationUnsupportedView: View {
    /// ドロップされた .app の URL。表示用にファイル名のみ使う。
    let droppedAppURL: URL?

    /// 解説ページを開くアクション。デフォルトは Constants の URL を `NSWorkspace` で開く。
    var onOpenDocumentation: () -> Void = {
        NSWorkspace.shared.open(AppConstants.ApplicationWallpaper.documentationURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(AppConstants.ApplicationWallpaper.unsupportedHeadline)
                    .font(.headline)
            }

            if let droppedAppURL {
                Text("検出されたアプリ: \(droppedAppURL.lastPathComponent)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(AppConstants.ApplicationWallpaper.unsupportedMessage)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: onOpenDocumentation) {
                    Label("ドキュメントを開く", systemImage: "arrow.up.right.square")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: 480, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG
#Preview {
    ApplicationUnsupportedView(
        droppedAppURL: URL(fileURLWithPath: "/Applications/Sample.app")
    )
    .padding()
    .frame(width: 540, height: 280)
}
#endif
