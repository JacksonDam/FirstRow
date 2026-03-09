import SwiftUI

struct FullscreenScenePresentation: Identifiable {
    let key: String
    let payload: [String: String]
    var id: String {
        if payload.isEmpty {
            return key
        }
        let serializedPayload = payload.sorted { lhs, rhs in lhs.key < rhs.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(key)|\(serializedPayload)"
    }
}

typealias FullscreenSceneBuilder = (FullscreenScenePresentation) -> AnyView
struct FullscreenSceneHost: View {
    let scene: FullscreenScenePresentation
    let builders: [String: FullscreenSceneBuilder]
    var body: some View {
        Group {
            if let builder = builders[scene.key] {
                builder(scene)
            } else {
                Color.black
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
    }
}
