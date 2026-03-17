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
