import SwiftUI

/// 下部パネル：アニメーションタイムライン
struct TimelineView: View {
    @ObservedObject var animationManager: AnimationManager
    @ObservedObject var editorManager: ImageEditorManager

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .frame(height: 1)

            HStack(spacing: 12) {
                // 再生コントロール
                playbackControls

                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 1, height: 22)

                // タイムライン表示
                timelineBar

                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 1, height: 22)

                // 時間表示
                timeDisplay

                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 1, height: 22)

                // FPS設定
                fpsControl
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .frame(height: 42)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12))
    }

    // MARK: - 再生コントロール

    private var playbackControls: some View {
        HStack(spacing: 6) {
            // 先頭に戻る
            Button(action: { animationManager.stop() }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("先頭に戻る")

            // 前のフレーム
            Button(action: { animationManager.previousFrame() }) {
                Image(systemName: "backward.frame.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("前のフレーム")

            // 再生/一時停止
            Button(action: {
                if animationManager.isPlaying {
                    animationManager.pause()
                } else {
                    animationManager.play()
                }
            }) {
                Image(systemName: animationManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(animationManager.isPlaying ? "一時停止" : "再生")

            // 次のフレーム
            Button(action: { animationManager.nextFrame() }) {
                Image(systemName: "forward.frame.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("次のフレーム")
        }
        .foregroundStyle(Color(white: 0.8))
    }

    // MARK: - タイムラインバー

    private var timelineBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景トラック（フラットなタイムライン帯）
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 5)

                // 進行バー
                Rectangle()
                    .fill(Color.accentColor.opacity(0.95))
                    .frame(
                        width: max(0, geometry.size.width * CGFloat(animationManager.currentTime / max(animationManager.totalDuration, 0.001))),
                        height: 5
                    )

                // シークヘッド
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(
                        x: max(0, geometry.size.width * CGFloat(animationManager.currentTime / max(animationManager.totalDuration, 0.001)) - 6)
                    )

                // キーフレームマーカー
                if let selectedID = editorManager.selectedLayerID,
                   let animation = animationManager.layerAnimations[selectedID] {
                    ForEach(animation.tracks) { track in
                        ForEach(track.keyframes) { keyframe in
                            let xPos = geometry.size.width * CGFloat(keyframe.time / max(animationManager.totalDuration, 0.001))
                            Diamond()
                                .fill(Color.yellow)
                                .frame(width: 8, height: 8)
                                .offset(x: xPos - 4, y: -10)
                        }
                    }
                }
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = max(0, min(1, value.location.x / geometry.size.width))
                        animationManager.seekTo(Double(ratio) * animationManager.totalDuration)
                    }
            )
        }
        .frame(height: 30)
    }

    // MARK: - 時間表示

    private var timeDisplay: some View {
        HStack(spacing: 2) {
            Text(formatTime(animationManager.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.82))
            Text("/")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.45))
            Text(formatTime(animationManager.totalDuration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.5))

            // 動画レイヤー選択中にアイコン表示
            if let selectedID = editorManager.selectedLayerID,
               let layer = editorManager.project.layers.first(where: { $0.id == selectedID }),
               layer.isVideoLayer {
                Image(systemName: "film")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
            }
        }
        .frame(width: 100)
    }

    // MARK: - FPS設定

    private var fpsControl: some View {
        HStack(spacing: 4) {
            Text("FPS")
                .font(.system(size: 10))
                .foregroundStyle(Color(white: 0.5))
            Picker("", selection: Binding(
                get: { Int(animationManager.fps) },
                set: { animationManager.fps = Double($0) }
            )) {
                Text("12").tag(12)
                Text("24").tag(24)
                Text("30").tag(30)
                Text("60").tag(60)
            }
            .frame(width: 60)
            .labelsHidden()
        }
        .foregroundStyle(Color(white: 0.78))
    }

    // MARK: - ヘルパー

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let frames = Int((time - floor(time)) * animationManager.fps)
        return String(format: "%d:%02d.%02d", minutes, seconds, frames)
    }
}

// MARK: - ダイヤモンド形状（キーフレームマーカー）

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2

        path.move(to: CGPoint(x: center.x, y: center.y - halfHeight))
        path.addLine(to: CGPoint(x: center.x + halfWidth, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + halfHeight))
        path.addLine(to: CGPoint(x: center.x - halfWidth, y: center.y))
        path.closeSubpath()

        return path
    }
}
