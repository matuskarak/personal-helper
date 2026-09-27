import ApplicationServices

/// Best-effort check for whether there's a focused, editable text field right now.
/// Used to decide whether dictated text should be auto-inserted or saved to memory
/// instead of silently pasting into nothing.
enum FocusValidator {
    /// `nil` = AX couldn't answer. Electron/Chromium apps (Claude, Slack, Arc…) intermittently
    /// fail the focused-element query even with a caret in a field (2026-09-24: Claude desktop,
    /// user pressed ⌃⌥V 4 s later). Unknown must not mean "no field" — callers paste anyway.
    static func hasEditableFocus() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef)
        guard appErr == .success, let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID() else {
            AppLogger.log("[FocusValidator] focused app nezistená (AX \(appErr.rawValue))")
            return nil
        }
        let focusedApp = focusedAppRef as! AXUIElement

        var focusedElementRef: CFTypeRef?
        let elErr = AXUIElementCopyAttributeValue(focusedApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard elErr == .success, let focusedElementRef, CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            AppLogger.log("[FocusValidator] focused element nezistený (AX \(elErr.rawValue))")
            return nil
        }
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

        AppLogger.log("[FocusValidator] zaostrený prvok nie je editovateľný (role: \(roleRef as? String ?? "?"))")
        return false
    }

    /// On-screen frame of the currently focused UI element, in Quartz global-display
    /// coordinates (origin top-left, Y down — what AX position/size attributes report).
    /// Callers needing AppKit screen coordinates (origin bottom-left, Y up) must flip it.
    ///
    /// - Parameter pid: query this app's AX tree directly instead of asking the system-wide
    ///   "currently focused application". Needed when a trigger (URL scheme / Apple Event)
    ///   activates our own app before this runs, which would otherwise make the system-wide
    ///   lookup report US as focused instead of the field the user was actually dictating into.
    static func focusedElementFrame(pid: pid_t? = nil) -> CGRect? {
        let focusedApp: AXUIElement
        if let pid {
            focusedApp = AXUIElementCreateApplication(pid)
        } else {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedAppRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
                  let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
            else { return nil }
            focusedApp = focusedAppRef as! AXUIElement
        }

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
