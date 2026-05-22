import SwiftUI

/// フォーム下や操作下に表示する小さなインラインエラー表示。
/// - 警告アイコン + 赤テキストを HStack で並べる。
/// - フルスクリーンエラー状態 (リトライ付き) とは用途が異なるので使い分けること。
struct InlineErrorLabel: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 12))
        }
        .foregroundColor(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
