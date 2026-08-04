import SwiftUI

/// Shared dimensions for readable, accessible app layouts.
enum SlowWalkLayout {
    static let contentMaxWidth: CGFloat = 680
    static let minimumTapTarget: CGFloat = 44
}

private struct SlowWalkReadableContentModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(
                maxWidth: SlowWalkLayout.contentMaxWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

extension View {
    /// Keeps reading lines comfortable on wide screens without constraining phones.
    func slowWalkReadableContent() -> some View {
        modifier(SlowWalkReadableContentModifier())
    }
}
