import CoreGraphics

struct ArrowAppearance {
    let symbolName: String
    let color: RGBA
    let fontSize: CGFloat
    let symbolWeight: SymbolRenderer.Weight
    let xOffset: CGFloat
    let glowPrimaryRadius: CGFloat
    let glowSecondaryRadius: CGFloat
    let glowPrimaryOpacity: Double
    let glowSecondaryOpacity: Double
}
