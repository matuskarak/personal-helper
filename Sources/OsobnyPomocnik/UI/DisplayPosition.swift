import AppKit

/// Per-physical-display position persistence, shared by the dictation and reading pills.
///
/// A raw screen-space `CGPoint` (what both pills used to save) silently falls off
/// `NSScreen.screens` whenever the point no longer lands on any current screen's frame —
/// which happens on *any* resolution or arrangement change, even for a monitor that never
/// moved. `CGDirectDisplayID` (from `NSScreen.deviceDescription["NSScreenNumber"]`) instead
/// identifies the physical display itself and stays stable across those changes and app
/// relaunches, so a position saved on "the external monitor" is found again as "the external
/// monitor" whatever its current resolution is — one dictionary entry per display, not one
/// point for the whole desktop.
enum DisplayPosition {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The monitor the user is actually looking at right now — the screen under the mouse
    /// cursor. `NSScreen.main` ("the screen with the key window") is unreliable for this
    /// app's non-activating panels, which often aren't key, or key on a stale screen.
    static func activeScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func load(_ key: String, screen: NSScreen?) -> CGPoint? {
        guard let id = screen.flatMap(displayID),
              let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]],
              let arr = dict[String(id)], arr.count == 2 else { return nil }
        return CGPoint(x: arr[0], y: arr[1])
    }

    static func save(_ key: String, screen: NSScreen?, point: CGPoint) {
        guard let id = screen.flatMap(displayID) else { return }
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        dict[String(id)] = [point.x, point.y]
        UserDefaults.standard.set(dict, forKey: key)
    }
}
