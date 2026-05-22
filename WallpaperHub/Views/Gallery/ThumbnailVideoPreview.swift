import SwiftUI
import MetalKit
import AVFoundation
import ImageIO
import WebKit

// MARK: - ThumbnailVideoPreview
// Why: ホバー時に動画/GIFを再生する NSViewRepresentable。

// MARK: - ホバー時の動画/GIFプレビュー

/// サムネイル上でホバー中に動画/GIFを再生するビュー
private final class PlayerLayerContainerView: NSView {
    weak var playerLayer: AVPlayerLayer?

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct ThumbnailVideoPreview: NSViewRepresentable {
    let item: WallpaperItem
    let library: WallpaperLibrary

    func makeNSView(context: Context) -> NSView {
        let container = PlayerLayerContainerView()
        container.wantsLayer = true

        guard let url = library.getWallpaperURL(for: item) else { return container }

        if item.type == .gif {
            // GIFの場合: NSImageViewでアニメーションGIF再生
            let imageView = NSImageView()
            imageView.animates = true
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(contentsOf: url)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            // 動画の場合: AVPlayerLayerで無音ループ再生
            let player = AVPlayer(url: url)
            player.volume = 0
            player.actionAtItemEnd = .none
            // ループ再生の通知
            context.coordinator.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }

            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspectFill
            container.layer?.addSublayer(playerLayer)
            container.playerLayer = playerLayer
            context.coordinator.playerLayer = playerLayer
            context.coordinator.player = player
            container.needsLayout = true

            player.play()
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // クリーンアップ: 再生停止＋通知解除
        if let endObserver = coordinator.endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        coordinator.player?.pause()
        coordinator.endObserver = nil
        coordinator.player = nil
        coordinator.playerLayer?.removeFromSuperlayer()
        if let container = nsView as? PlayerLayerContainerView {
            container.playerLayer = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var player: AVPlayer?
        var playerLayer: AVPlayerLayer?
        var endObserver: NSObjectProtocol?
    }
}
