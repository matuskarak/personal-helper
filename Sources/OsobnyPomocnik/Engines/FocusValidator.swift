import ApplicationServices

/// Best-effort check for whether there's a focused, editable text field right now.
/// Used to decide whether dictated text should be auto-inserted or saved to memory
/// instead of silently pasting into nothing.
enum FocusValidator {
    static func hasEditableFocus() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
              let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
        else { return false }
        let focusedApp = focusedAppRef as! AXUIElement

        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef, CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else { return false }
        let element = focusedElementRef as! AXUIElement

        // Known editable roles cover most native macOS text fields/areas.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            let editableRoles: Set<String> = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXSearchField"
            ]
            if editableRoles.contains(role) { return true }
        }

        // Fallback: many custom editors (web text areas in Electron/Chromium apps,
        // code editors) don't report a standard role but DO expose a settable
        // value — treat that as editable too.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        return false
    }

    /// On-screen frame of the currently focused UI element, in Quartz global-display
    /// coordinates (origin top-left, Y down — what AX position/size attributes report).
    /// Callers needing AppKit screen coordinates (origin bottom-left, Y up) must flip it.
    static func focusedElementFrame() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
              let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
        else { return nil }
        let focusedApp = focusedAppRef as! AXUIElement

        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef, CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedElementRef as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size  = CGSize.zero
        guard AXValueGetValue((posRef as! AXValue), .cgPoint, &point),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size)
        else { return nil }

        return CGRect(origin: point, size: size)
    }
}
