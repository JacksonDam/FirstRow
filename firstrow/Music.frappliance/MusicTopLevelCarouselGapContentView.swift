import SwiftUI

struct MusicTopLevelCarouselGapContentView: View {
    private enum ArtworkSource {
        case staticImages([NSImage?])
        case dynamic(
            resolvedArtworkCount: Int?,
            initialLoadedArtworkCount: Int,
            artworkForGlobalIndex: (Int) -> NSImage?,
            prefetchIfNeededForSerial: (Int) -> Void,
            phaseResetKey: String,
        )
    }

    private let artworkSource: ArtworkSource
    let baseIconSize: CGFloat
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let preserveArtworkAspectRatio: Bool
    let exitOverlayOpacity: Double


    init(
        artworkImages: [NSImage?],
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        preserveArtworkAspectRatio: Bool = false,
        exitOverlayOpacity: Double = 0,
    ) {
        artworkSource = .staticImages(artworkImages)
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.preserveArtworkAspectRatio = preserveArtworkAspectRatio
        self.exitOverlayOpacity = exitOverlayOpacity
    }

    init(
        artworkCount: Int?,
        initialLoadedArtworkCount: Int,
        artworkForGlobalIndex: @escaping (Int) -> NSImage?,
        prefetchIfNeededForSerial: @escaping (Int) -> Void,
        baseIconSize: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        preserveArtworkAspectRatio: Bool = false,
        exitOverlayOpacity: Double = 0,
        phaseResetKey: String,
    ) {
        artworkSource = .dynamic(
            resolvedArtworkCount: artworkCount,
            initialLoadedArtworkCount: initialLoadedArtworkCount,
            artworkForGlobalIndex: artworkForGlobalIndex,
            prefetchIfNeededForSerial: prefetchIfNeededForSerial,
            phaseResetKey: phaseResetKey,
        )
        self.baseIconSize = baseIconSize
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.preserveArtworkAspectRatio = preserveArtworkAspectRatio
        self.exitOverlayOpacity = exitOverlayOpacity
    }

    var body: some View {
        Group {
            if hasRenderableArtworks {
                ZStack {
                    let side = baseIconSize * 1.2
                    LayerHost<CoverCarouselLayerController>(configuration: CoverCarouselConfiguration(
                        source: layerSource,
                        baseIconSize: baseIconSize,
                        horizontalOffset: horizontalOffset,
                        verticalOffset: verticalOffset,
                        preserveArtworkAspectRatio: preserveArtworkAspectRatio,
                    )).frame(width: side, height: side + 100)
                        // Inserted without SwiftUI's transition: a platform view inserted mid-transition
                        // could stay on a blank snapshot of itself.
                        .transaction { $0.disablesAnimations = true }
                    // Only present while it shows: above a platform view, SwiftUI could keep drawing
                    // this black overlay at full strength after its opacity had gone back to 0.
                    if exitOverlayOpacity > 0.001 {
                        Rectangle().fill(Color.black).frame(
                            width: max(baseIconSize * 3.75, 1500),
                            height: max(baseIconSize * 4.0, 1200),
                        ).offset(x: horizontalOffset, y: verticalOffset).allowsHitTesting(false).opacity(exitOverlayOpacity).zIndex(10000)
                    }
                }
            } else {
                EmptyView()
            }
        }
    }

    private var layerSource: CoverCarouselConfiguration.Source {
        switch artworkSource {
        case let .staticImages(images):
            .images(images)
        case let .dynamic(resolvedArtworkCount, initialLoadedArtworkCount, artworkForGlobalIndex, prefetchIfNeededForSerial, phaseResetKey):
            .dynamic(
                resolvedArtworkCount: resolvedArtworkCount,
                loadedArtworkCount: initialLoadedArtworkCount,
                artworkForGlobalIndex: artworkForGlobalIndex,
                prefetchIfNeededForSerial: prefetchIfNeededForSerial,
                phaseResetKey: phaseResetKey,
            )
        }
    }

    private var hasRenderableArtworks: Bool {
        switch artworkSource {
        case let .staticImages(artworkImages):
            !artworkImages.isEmpty
        case let .dynamic(_, initialLoadedArtworkCount, _, _, _):
            initialLoadedArtworkCount > 0
        }
    }

}
