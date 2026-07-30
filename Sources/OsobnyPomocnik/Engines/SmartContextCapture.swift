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
        let appName: String?
        let windowTitle: String?
    }

    /// - Parameter captureScreenshot: pass `false` to get just the app identity and window
    ///   title. Every dictation needs that much for quality tracking, but only Smart
    ///   diktovanie needs the pixels — and the actual capture is the expensive part.
    func captureFrontmostContext(captureScreenshot: Bool = true) async -> Context {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let appName  = app?.localizedName
        guard let pid = app?.processIdentifier else {
            return Context(image: nil, bundleID: bundleID, appName: appName, windowTitle: nil)
        }

        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
            let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.isOnScreen })
        else {
            return Context(image: nil, bundleID: bundleID, appName: appName, windowTitle: nil)
        }

        guard captureScreenshot else {
            return Context(image: nil, bundleID: bundleID, appName: appName, windowTitle: window.title)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width       = max(Int(window.frame.width  * 2), 2)
        cfg.height      = max(Int(window.frame.height * 2), 2)
        cfg.scalesToFit = false
        cfg.showsCursor = false

        let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Context(image: image, bundleID: bundleID, appName: appName, windowTitle: window.title)
    }
}
