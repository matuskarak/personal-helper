import Cocoa

final class TextExtractor: Sendable {
    static let shared = TextExtractor()
    private init() {}

    /// Simulates ⌘C in the frontmost app, reads the result from the pasteboard.
    /// Restores the original clipboard content afterwards.
    func extractSelected() async -> String? {
        let pasteboard = NSPasteboard.general

        // Snapshot current clipboard
        let savedTypes = pasteboard.types ?? []
        let savedData: [(NSPasteboard.PasteboardType, Data)] = savedTypes.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
        let previousCount = pasteboard.changeCount

        // Simulate ⌘C
        await simulateCopy()

        // Wait up to 300 ms for the clipboard to update
        let updated = await waitForClipboardChange(from: previousCount, timeout: 0.3)
        guard updated else {
            restore(pasteboard, with: savedData)
            return nil
        }

        let text = pasteboard.string(forType: .string)

        // Restore original clipboard
        restore(pasteboard, with: savedData)

        return text?.isEmpty == false ? text : nil
    }

    // MARK: - Private helpers

    @MainActor
    private func simulateCopy() async {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 8 /* C */, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 8,         keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func waitForClipboardChange(from initialCount: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
            if NSPasteboard.general.changeCount != initialCount { return true }
        }
        return false
    }

    private func restore(_ pasteboard: NSPasteboard, with data: [(NSPasteboard.PasteboardType, Data)]) {
        pasteboard.clearContents()
        for (type, d) in data {
            pasteboard.setData(d, forType: type)
        }
    }
}
