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
        let t0 = Date()
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let appName  = app?.localizedName
        AppLogger.log("[SmartContextCapture] start — app=\(appName ?? "?") bundleID=\(bundleID ?? "?") wantsScreenshot=\(captureScreenshot)")

        guard let pid = app?.processIdentifier else {
            AppLogger.log("[SmartContextCapture] ⚠️ no frontmost app pid — aborting")
            return Context(image: nil, bundleID: bundleID, appName: appName, windowTitle: nil)
        }

        // Pick the LARGEST on-screen window for this pid, not just the first one
        // SCShareableContent happens to return — ordering isn't guaranteed to be z-order/main
        // window first. An app can have extra small on-screen windows at the same time (e.g. a
        // browser's picture-in-picture video player, a mini popup) that would otherwise get
        // captured instead of the actual window the user is dictating into.
        let content = await Self.withCaptureTimeout("zoznam okien") {
            try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        guard
            let content,
            let window = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.isOnScreen })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else {
            AppLogger.log("[SmartContextCapture] ⚠️ no shareable window found for pid \(pid) — check Screen Recording permission?")
            return Context(image: nil, bundleID: bundleID, appName: appName, windowTitle: nil)
        }
        AppLogger.log("[SmartContextCapture] window found — title=\"\(window.title ?? "")\" frame=\(Int(window.frame.width))x\(Int(window.frame.height))")

        guard captureScreenshot else {
            AppLogger.log("[SmartContextCapture] done (identity only) — \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            return Context(image: nil, bundleID: bundleID, appName: appName, windowTitle: window.title)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        // The model only needs to read on-screen text/UI, not full Retina pixels — capping the
        // longer side keeps the base64 JPEG payload (and vision-token cost/latency) down on
        // large or external monitors. 1280 measurably blurred small UI text on Retina displays
        // (confirmed by inspecting a saved screenshot — see DictationHistoryStore); 1800 is a
        // better legibility/cost tradeoff.
        let maxSide: CGFloat = 1800
        let longSide = max(window.frame.width, window.frame.height)
        let scale = longSide > 0 ? min(1, maxSide / longSide) : 1
        cfg.width       = max(Int(window.frame.width  * scale), 2)
        cfg.height      = max(Int(window.frame.height * scale), 2)
        cfg.scalesToFit = false
        cfg.showsCursor = false

        let image = await Self.withCaptureTimeout("screenshot") {
            try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if let image {
            AppLogger.log("[SmartContextCapture] screenshot captured — \(image.width)x\(image.height)px, \(ms)ms")
        } else {
            AppLogger.log("[SmartContextCapture] ⚠️ screenshot capture failed (nil image), \(ms)ms — check Screen Recording permission")
        }
        return Context(image: image, bundleID: bundleID, appName: appName, windowTitle: window.title)
    }

    /// ScreenCaptureKit calls, with a hard ceiling on how long any of them may take.
    ///
    /// `SCStream` init calls `CMAudioDeviceClockCreate`, so screen capture needs the CoreAudio
    /// HAL — and when the HAL is wedged (measured 2026-08-31: the USB mic re-enumerated, its
    /// device was torn down mid-open, coreaudiod spun at 50% and stopped answering) these calls
    /// never return at all. Without a ceiling the whole dictation hung until the app was killed.
    ///
    /// A healthy capture takes 80–400 ms, so 8 s only ever fires on a genuine hang and never
    /// costs a working dictation its screen context. The abandoned call is left running: there
    /// is no way to cancel it, and it sits in a mach_msg the HAL eventually releases.
    private static let captureTimeout = Duration.seconds(8)

    private static func withCaptureTimeout<T>(_ label: String, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                // A thrown sleep means the group was cancelled because the real call already
                // finished — that is the normal path and must stay silent.
                do { try await Task.sleep(for: captureTimeout) } catch { return nil }
                AppLogger.log("[SmartContextCapture] ⚠️ \(label) neodpovedal do 8 s — pokračujem bez kontextu obrazovky (zaseknutý CoreAudio/ScreenCaptureKit?)")
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
