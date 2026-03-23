#if os(macOS)
    import AppKit
#endif
import AVKit
import SwiftUI

#if os(macOS)
    struct VideoPlayerView: NSViewRepresentable {
        let player: AVPlayer
        var videoGravity: AVLayerVideoGravity = .resizeAspect
        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = videoGravity
            playerLayer.backgroundColor = NSColor.black.cgColor
            playerLayer.frame = view.bounds
            view.wantsLayer = true
            view.layer = playerLayer
            return view
        }

        func updateNSView(_ nsView: NSView, context _: Context) {
            if let layer = nsView.layer as? AVPlayerLayer {
                layer.player = player
                layer.videoGravity = videoGravity
                layer.frame = nsView.bounds
            }
        }
    }
#else
    final class PlayerLayerContainerView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }

    struct VideoPlayerView: UIViewRepresentable {
        let player: AVPlayer
        var videoGravity: AVLayerVideoGravity = .resizeAspect
        func makeUIView(context _: Context) -> PlayerLayerContainerView {
            let view = PlayerLayerContainerView()
            view.backgroundColor = .black
            view.playerLayer.player = player
            view.playerLayer.videoGravity = videoGravity
            return view
        }

        func updateUIView(_ uiView: PlayerLayerContainerView, context _: Context) {
            uiView.playerLayer.player = player
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
#endif
