import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - NoWallpaperCard
// Why: 壁紙未選択カード（壁紙を解除するアクション）。

// MARK: - 壁紙を設定しないカード

/// ギャラリー先頭に表示する「壁紙を設定しない」カード
struct NoWallpaperCard: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var isHovering = false
    @State private var glowAngle: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // サムネイル部分
            ZStack {
                // macOSデスクトップ風の背景
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.15, green: 0.35, blue: 0.65),
                        Color(red: 0.25, green: 0.20, blue: 0.55)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .aspectRatio(16/10, contentMode: .fill)

                // 透過アイコン
                Image(systemName: "eye.slash.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(.white.opacity(0.5))
            }
            .aspectRatio(16/10, contentMode: .fit)
            .cornerRadius(8)
            .overlay(
                // スポットライト光エフェクト
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.6),
                                Color.accentColor.opacity(0.8),
                                Color.white.opacity(0.6),
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.0),
                            ]),
                            center: .center,
                            angle: .degrees(glowAngle)
                        ),
                        lineWidth: isHovering ? 2.5 : 0
                    )
                    .opacity(isHovering ? 1 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(isHovering ? 0.4 : 0), lineWidth: 4)
                    .blur(radius: 4)
            )
            .shadow(
                color: isHovering ? Color.accentColor.opacity(0.5) : Color.clear,
                radius: isHovering ? 10 : 0,
                x: 0,
                y: 0
            )
            .brightness(isHovering ? 0.05 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(false)

            // タイトル
            Text("壁紙を設定しない")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.primary)

            // サブテキスト
            Text("macOSの壁紙を表示")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                withAnimation(.linear(duration: 0).repeatForever(autoreverses: false)) {
                    glowAngle = 180
                }
            } else {
                glowAngle = 0
            }
        }
        .onTapGesture {
            appDelegate.clearAndEnableTransparentMode()
        }
    }
}
