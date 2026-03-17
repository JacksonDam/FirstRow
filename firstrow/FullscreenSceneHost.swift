import SwiftUI

struct FullscreenSceneHost<Content: View>: View {
    let scene: FullscreenScenePresentation
    let content: Content

    init(scene: FullscreenScenePresentation, @ViewBuilder content: (FullscreenScenePresentation) -> Content) {
        self.scene = scene
        self.content = content(scene)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}
