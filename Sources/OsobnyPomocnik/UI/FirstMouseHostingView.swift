import AppKit
import SwiftUI

/// `NSHostingView` that acts on the click which activates its window, instead of
/// swallowing it.
///
/// This app runs as an accessory (`LSUIElement` + `.accessory` activation policy), so it
/// drops out of frontmost easily — clicking any other app is enough. AppKit's default is
/// that a click into a non-key window only activates it, and the view never sees that
/// event. The result was Preferences needing two or three clicks for anything: the first
/// click just handed focus back to the app.
///
/// Overriding `acceptsFirstMouse` is the sanctioned fix and is scoped to the click itself —
/// unlike switching the activation policy to `.regular`, which would work but also put a
/// Dock icon on a menu-bar-only app.
///
/// Not needed for the floating pill: that's a `.nonactivatingPanel`, which already
/// delivers clicks without taking activation.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used — created in code") }
}
