import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - PreviewLoadingRing
// Why: プレビュー読み込み/設定中のローディング進捗表示。

struct PreviewLoadingRing: View {
    let progress: Double
    let title: String

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var lineWidth: CGFloat {
        9 + CGFloat(clampedProgress) * 15
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color.accentColor.opacity(0.96),
                                Color.white.opacity(0.78)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text("\(Int(clampedProgress * 100))%")
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 150, height: 150)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(width: 150, height: 250)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.24), radius: 24, x: 0, y: 14)
    }
}
