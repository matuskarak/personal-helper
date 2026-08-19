import AppKit
import AVFoundation
@preconcurrency import ApplicationServices

@MainActor
final class PermissionsChecker {
    static let shared = PermissionsChecker()
    private init() {}

    func requestAllIfNeeded() {
        if !isAccessibilityGranted {
            showAccessibilityPrompt()
        }
        requestMicrophone()
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var isMicrophoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func showAccessibilityPrompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
}
