import SwiftUI
import AppKit

/// Pointing-hand cursor while the pointer sits over a custom-drawn clickable control.
///
/// Deliberately NOT applied to every button. macOS convention is that a real push button
/// (`.bordered`, `.borderedProminent`) keeps the arrow — the hand means "link-like", and
/// putting it on ordinary buttons makes an app read as a web page. It belongs on the
/// borderless controls this app draws itself: sidebar rows, bare text buttons, clickable
/// list rows — the places where nothing else tells you the thing can be clicked. That
/// matters more here than in a typical app, since the audience can't rely on spotting
/// subtle visual affordances.
///
/// push/pop rather than a plain `NSCursor.set()`: `set()` is undone by the next cursor
/// update any other view triggers, so the hand flickers back to an arrow while the pointer
/// hasn't moved. The `pushed` flag keeps the stack balanced — an unbalanced pop leaves the
/// hand stuck over the whole window, and a view that disappears mid-hover (a history row
/// deleted from under the pointer) never gets its exit callback, which is exactly how that
/// happens.
private struct PointingHandOnHover: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }
}

extension View {
    /// Marks a custom-drawn control as clickable — see `PointingHandOnHover` for why this
    /// isn't simply put on every button.
    func pointingHandCursor() -> some View { modifier(PointingHandOnHover()) }
}
