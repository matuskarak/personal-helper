import AppKit
import ScreenCaptureKit

/// Captures a screenshot of the frontmost app's active window (not the whole screen)
/// plus its bundle ID and window title, used as context for Smart diktovanie.
@MainActor
final class SmartContextCapture {
    static let shared = SmartContextCapture()
    private init() {}

    struct Context {
        let image: CGImage?
        let bundleID: String?
        let windowTitle: String?
    }

    func captureFrontmostContext() async -> Context {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        guard let pid = app?.processIdentifier else {
            return Context(image: nil, bundleID: bundleID, windowTitle: nil)
        }

        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
            let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.isOnScreen })
        else {
            return Context(image: nil, bundleID: bundleID, windowTitle: nil)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width       = max(Int(window.frame.width  * 2), 2)
        cfg.height      = max(Int(window.frame.height * 2), 2)
        cfg.scalesToFit = false
        cfg.showsCursor = false

        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Context(image: image, bundleID: bundleID, windowTitle: window.title)
    }
}
