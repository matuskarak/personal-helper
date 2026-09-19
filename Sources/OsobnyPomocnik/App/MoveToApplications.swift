import AppKit
import Darwin

/// First-launch "move to /Applications" prompt — LetsMove-style, minimal, in-house (no
/// dependency).
///
/// Testers download the app as a zip/DMG and often run it straight from `~/Downloads`, from the
/// mounted DMG volume, or from an App-Translocation path (macOS's quarantine sandbox for apps
/// run in place from an unregistered location — `/private/var/folders/.../AppTranslocation/...`).
/// Running from any of those breaks Sparkle's relative-path update mechanics and leaves a stray
/// copy behind. This offers, once per launch, to move the bundle into `/Applications` (falling
/// back to `~/Applications` only when `/Applications` genuinely isn't writable) and relaunches
/// from there.
@MainActor
enum MoveToApplications {

    /// Passed to the relaunched instance so it never re-prompts, no matter what its bundle
    /// path looks like (a relaunched /Applications copy is itself translocated the first time
    /// Gatekeeper sees it, before quarantine is stripped from it below).
    private static let relaunchMarkerArgument = "--moved-to-applications"

    /// Shows the prompt if the app isn't running from an Applications folder, and handles the
    /// move + relaunch if the user agrees. Call early in `applicationDidFinishLaunching`,
    /// before onboarding is shown. Returns `true` when the app is about to relaunch from the
    /// new location and terminate itself — the caller should return immediately in that case
    /// and not start hotkeys/onboarding in the instance that's about to quit.
    @MainActor
    static func promptIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path

        if ProcessInfo.processInfo.arguments.contains(relaunchMarkerArgument) {
            AppLogger.log("[MoveToApplications] launched by our own relaunch, never prompting: \(path)")
            return false
        }

        #if DEBUG
        // Developers run straight from the SwiftPM/Xcode build dir or this repo's own checkout
        // — never prompt there. Simplest robust rule: skip in DEBUG unless the path looks like
        // an actual distributed copy (mounted DMG, translocated, or sitting in Downloads) —
        // those cases still get the real check below, e.g. a debug build shared with a tester.
        let looksLikeDevLocation = path.contains("/.build/") || path.contains("/Cluade Projects/")
        let looksLikeDistributedCopy = path.hasPrefix("/Volumes/")
            || path.contains("AppTranslocation")
            || path.contains("/Downloads/")
        if looksLikeDevLocation && !looksLikeDistributedCopy {
            AppLogger.log("[MoveToApplications] DEBUG build in dev location, skipping: \(path)")
            return false
        }
        #endif

        // A quarantined app that Finder never moved is App-Translocated even when its visible
        // path sits inside /Applications — so "is the bundle path in /Applications" is the
        // wrong test on its own. Resolve the pre-translocation ORIGINAL path first and decide
        // from that.
        let translocationCheck = translocationStatus(of: bundleURL)
        let effectivePath: String
        switch translocationCheck {
        case .translocated(let original):
            AppLogger.log("[MoveToApplications] translocated view \(path) — original: \(original.path)")
            effectivePath = original.path
        case .notTranslocated, .unknown:
            effectivePath = path
        }

        guard !isInApplicationsFolder(URL(fileURLWithPath: effectivePath)) else {
            // Installed already — just translocated because the copy on disk still carries the
            // quarantine flag (e.g. it was placed there by something other than Finder's
            // move-from-DMG, or a previous run of this same logic left it quarantined). The
            // user already approved running it via the Gatekeeper prompt that got us here, so
            // strip quarantine from the real bundle on disk and continue this launch in place
            // — no prompt, no relaunch.
            if case .translocated(let original) = translocationCheck {
                AppLogger.log("[MoveToApplications] original is already inside Applications, stripping quarantine in place and continuing: \(original.path)")
                stripQuarantineRecursively(at: original)
            } else {
                AppLogger.log("[MoveToApplications] already in Applications, skipping: \(path)")
            }
            cleanUpLegacyDuplicates()
            return false
        }

        // What actually gets copied is the running bundle (bundleURL) — the translocated view
        // still resolves to real bytes via the translocation shim, and copying it strips
        // translocation the same way Finder's move does. Only cleanup afterwards needs the
        // resolved original path, to know whether it's safe to trash (e.g. a plain Downloads
        // copy) or must be left alone (a mounted DMG).
        let resolvedOriginal = translocationCheck.originalOrSelf(bundleURL)

        // Running from a mounted DMG or ~/Downloads is never an intentional install location for
        // this app — it's always a leftover from opening the app straight out of the disk image
        // or the download, sometimes even after the user already dragged a copy into Applications
        // themselves and macOS launched the blocked DMG copy instead (confirmed from a real
        // tester log: they'd already moved it and clicked "Open Anyway", then got asked to move it
        // again). Asking about a step the user may have already done is just confusing, so skip
        // the prompt and move silently; only surface an alert if the copy itself fails.
        if isOnMountedDMGOrDownloads(URL(fileURLWithPath: effectivePath)) {
            AppLogger.log("[MoveToApplications] running from a mounted DMG or Downloads, moving silently: \(effectivePath)")
            return performMove(from: bundleURL, resolvedOriginal: resolvedOriginal)
        }

        AppLogger.log("[MoveToApplications] running outside Applications, prompting: \(effectivePath)")

        // LSUIElement app has no Dock icon / frontmost window by default — activate first so
        // the alert doesn't appear behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Presunúť Ozvenu do Aplikácií?"
        alert.informativeText = "Ozvena beží mimo priečinka Aplikácie. Aby fungovali automatické aktualizácie, presuň ju tam — stačí jedno kliknutie."
        alert.addButton(withTitle: "Presunúť do Aplikácií")
        alert.addButton(withTitle: "Teraz nie")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            AppLogger.log("[MoveToApplications] user declined, continuing from current location — will ask again next launch")
            return false
        }

        return performMove(from: bundleURL, resolvedOriginal: resolvedOriginal)
    }

    /// True when `url` (the resolved, pre-translocation original) sits on a mounted DMG volume
    /// or anywhere under `~/Downloads` — the two locations this app is only ever run from by
    /// accident, never intentionally installed to.
    private static func isOnMountedDMGOrDownloads(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Volumes/") { return true }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return false
        }
        let downloadsPath = downloads.standardizedFileURL.path
        return path == downloadsPath || path.hasPrefix(downloadsPath + "/")
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let candidates = [
            URL(fileURLWithPath: "/Applications").standardizedFileURL,
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL
        ]
        return candidates.contains(parent)
    }

    // MARK: - Legacy bundle cleanup (rename transition)

    /// Trashes any OTHER `.app` in `/Applications` or `~/Applications` that shares our bundle
    /// identifier — a leftover from the app's rename (`OsobnyPomocnik.app` → `Ozvena.app`, see
    /// CLAUDE.md, 2026-09-19). The bundle identifier itself did NOT change (UserDefaults,
    /// Keychain and TCC are all keyed on it), so an old `OsobnyPomocnik.app` a tester dragged in
    /// before the rename and a newer `Ozvena.app` they later installed can end up sitting side
    /// by side with the identical bundle id — that confuses Launch Services (which copy does
    /// `open -b sk.matuskarak.osobny-pomocnik` or the `osobnypomocnik://`/`ozvena://` URL scheme
    /// launch, or a Sparkle re-check, actually pick?) and just wastes disk space.
    ///
    /// Called every time this launch already finds itself installed in an Applications folder
    /// (see call site above) — cheap (a handful of directory entries), and safe to repeat every
    /// launch. Never touches the bundle that is actually running.
    @MainActor
    private static func cleanUpLegacyDuplicates() {
        guard let ourBundleID = Bundle.main.bundleIdentifier else { return }
        let runningURL = Bundle.main.bundleURL.standardizedFileURL
        let fm = FileManager.default
        let foldersToScan = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        // ponytail: only the two names this app has ever shipped under — runs on every launch, so
        // no scan of the whole Applications folder. Add a name here if the bundle is renamed again.
        let knownNames = ["OsobnyPomocnik.app", "Ozvena.app"]
        for folder in foldersToScan {
            for name in knownNames {
                let entry = folder.appendingPathComponent(name)
                let standardized = entry.standardizedFileURL
                guard standardized != runningURL, fm.fileExists(atPath: entry.path) else { continue }
                // Same bundle id = an older copy of this very app, not some unrelated app.
                guard let otherBundle = Bundle(url: entry), otherBundle.bundleIdentifier == ourBundleID else { continue }
                do {
                    try fm.trashItem(at: entry, resultingItemURL: nil)
                    AppLogger.log("[MoveToApplications] trashed legacy duplicate \(entry.path) (same bundle id \(ourBundleID), different name than running \(runningURL.path))")
                } catch {
                    AppLogger.log("[MoveToApplications] failed to trash legacy duplicate \(entry.path): \(error)")
                }
            }
        }
    }

    // MARK: - Move

    private static func performMove(from sourceURL: URL, resolvedOriginal: URL) -> Bool {
        let fm = FileManager.default
        let name = sourceURL.lastPathComponent
        let systemDest = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)

        switch copy(sourceURL, to: systemDest, fm: fm) {
        case .success(let finalDest):
            stripQuarantineRecursively(at: finalDest)
            cleanUpSourceIfSafe(resolvedOriginal, fm: fm)
            relaunch(at: finalDest)
            return true

        case .failure(let error) where isPermissionError(error):
            // /Applications genuinely isn't writable (EACCES/EPERM) — every user can write to
            // ~/Applications without elevation, so fall back there. Any other failure kind
            // (disk full, bad copy, …) is reported as-is instead of silently trying a second
            // location.
            AppLogger.log("[MoveToApplications] /Applications not writable (\(error)), falling back to ~/Applications")
            let userApplications = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            do {
                try fm.createDirectory(at: userApplications, withIntermediateDirectories: true)
            } catch {
                AppLogger.log("[MoveToApplications] failed to create ~/Applications: \(error)")
                showFailureAlert(error.localizedDescription)
                return false
            }
            let userDest = userApplications.appendingPathComponent(name)
            switch copy(sourceURL, to: userDest, fm: fm) {
            case .success(let finalDest):
                stripQuarantineRecursively(at: finalDest)
                cleanUpSourceIfSafe(resolvedOriginal, fm: fm)
                relaunch(at: finalDest)
                return true
            case .failure(let error):
                AppLogger.log("[MoveToApplications] failed to copy to ~/Applications too: \(error)")
                showFailureAlert("Nepodarilo sa skopírovať appku ani do /Applications, ani do ~/Applications.")
                return false
            }

        case .failure(let error):
            AppLogger.log("[MoveToApplications] failed to copy to /Applications: \(error)")
            showFailureAlert(error.localizedDescription)
            return false
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
        }
        return nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EACCES) || nsError.code == Int(EPERM))
    }

    /// Copies the bundle to `dest`. Copies to a temp sibling first and only swaps it into place
    /// with `replaceItemAt` once the copy is fully on disk — so a failure partway through a copy
    /// (disk full, source read error…) can never leave `dest` missing or half-written, and any
    /// existing copy at `dest` is only removed at the moment it's atomically replaced, not
    /// trashed upfront. Returns `dest` on success.
    private static func copy(_ source: URL, to dest: URL, fm: FileManager) -> Result<URL, Error> {
        let tmpDest = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            // Copy, not move: the source may be on a read-only DMG volume or translocated.
            try fm.copyItem(at: source, to: tmpDest)
        } catch {
            AppLogger.log("[MoveToApplications] copy to temp \(tmpDest.path) failed: \(error)")
            try? fm.removeItem(at: tmpDest)
            return .failure(error)
        }
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmpDest)
                AppLogger.log("[MoveToApplications] replaced existing copy at \(dest.path)")
            } else {
                try fm.moveItem(at: tmpDest, to: dest)
            }
            AppLogger.log("[MoveToApplications] copied \(source.path) -> \(dest.path)")
            return .success(dest)
        } catch {
            AppLogger.log("[MoveToApplications] swapping temp copy into \(dest.path) failed: \(error)")
            try? fm.removeItem(at: tmpDest)
            return .failure(error)
        }
    }

    /// Deletes the original only when it's clearly safe to: a plain copy sitting directly in
    /// `~/Downloads`. Leaves mounted DMG volumes alone (there's nothing to delete — it's the
    /// disk image).
    private static func cleanUpSourceIfSafe(_ resolvedOriginal: URL, fm: FileManager) {
        let path = resolvedOriginal.path
        if path.hasPrefix("/Volumes/") {
            AppLogger.log("[MoveToApplications] source is a mounted DMG volume, leaving it in place: \(path)")
            return
        }
        trashIfDirectlyInDownloads(resolvedOriginal, fm: fm)
    }

    private static func trashIfDirectlyInDownloads(_ url: URL, fm: FileManager) {
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              url.deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL
        else {
            AppLogger.log("[MoveToApplications] original \(url.path) isn't directly in Downloads, leaving it in place")
            return
        }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            AppLogger.log("[MoveToApplications] moved original \(url.path) to Trash")
        } catch {
            AppLogger.log("[MoveToApplications] failed to trash original \(url.path): \(error)")
        }
    }

    // MARK: - Quarantine

    /// Strips `com.apple.quarantine` from the bundle root and every file inside it. The app is
    /// already running, which means the user already approved it via Gatekeeper — leaving the
    /// flag on the copy (or on an already-installed original) would make Gatekeeper translocate
    /// it again on the very next launch and re-show the "not opened" dialog, so this is what
    /// LetsMove does after every move. `ENOATTR` (attribute never set) is expected and silent;
    /// anything else is logged but not fatal — worst case Gatekeeper prompts again.
    private static func stripQuarantineRecursively(at url: URL) {
        removeQuarantineXattr(url)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { enumURL, error in
                AppLogger.log("[MoveToApplications] quarantine strip: enumeration error at \(enumURL.path): \(error)")
                return true
            }
        ) else { return }
        for case let fileURL as URL in enumerator {
            removeQuarantineXattr(fileURL)
        }
        AppLogger.log("[MoveToApplications] stripped quarantine recursively from \(url.path)")
    }

    private static func removeQuarantineXattr(_ url: URL) {
        let result = url.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
        if result != 0 && errno != ENOATTR {
            AppLogger.log("[MoveToApplications] removexattr(com.apple.quarantine) failed for \(url.path): errno \(errno)")
        }
    }

    // MARK: - Relaunch

    private static func relaunch(at destination: URL) {
        AppLogger.log("[MoveToApplications] relaunching from \(destination.path)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // Loop guard: the relaunched instance sees this and never prompts again, however its
        // own bundle path (or translocation status) looks at that point.
        configuration.arguments = [relaunchMarkerArgument]
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    AppLogger.log("[MoveToApplications] relaunch failed: \(error) — staying in old location")
                    return
                }
                AppLogger.log("[MoveToApplications] relaunched successfully, terminating old instance")
                NSApp.terminate(nil)
            }
        }
    }

    private static func showFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Presun do Aplikácií zlyhal"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - App Translocation

    private enum TranslocationStatus {
        case translocated(original: URL)
        case notTranslocated
        /// The SPI call itself failed (symbol missing, or the call errored) — callers fall back
        /// to treating the bundle's own path as authoritative, same as before this existed.
        case unknown

        func originalOrSelf(_ bundleURL: URL) -> URL {
            if case .translocated(let original) = self { return original }
            return bundleURL
        }
    }

    /// Checks whether `url` is an App-Translocation view and, if so, resolves the
    /// pre-translocation original path — via the private `SecTranslocateIsTranslocatedURL` /
    /// `SecTranslocateCreateOriginalPathForURL` SPIs (Security.framework; no public header
    /// ships for them, so they're loaded by hand via `dlsym`).
    ///
    /// Signatures (confirmed against the shipping dylib, no header exists to check against):
    /// `Boolean SecTranslocateIsTranslocatedURL(CFURLRef path, bool *isTranslocated, CFErrorRef *error)`
    /// `CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef translocatedPath, CFErrorRef *error)`
    private static func translocationStatus(of url: URL) -> TranslocationStatus {
        typealias IsTranslocatedFn =
            @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias CreateOriginalPathFn =
            @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            AppLogger.log("[MoveToApplications] dlopen(Security.framework) failed: \(String(describing: dlerror()))")
            return .unknown
        }
        defer { dlclose(handle) }

        guard let isTranslocatedSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let createOriginalSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
        else {
            AppLogger.log("[MoveToApplications] SecTranslocate SPI symbols not found")
            return .unknown
        }
        let isTranslocatedFn = unsafeBitCast(isTranslocatedSym, to: IsTranslocatedFn.self)
        let createOriginalFn = unsafeBitCast(createOriginalSym, to: CreateOriginalPathFn.self)

        var isTranslocated = DarwinBoolean(false)
        var checkError: Unmanaged<CFError>?
        let checkOK = isTranslocatedFn(url as CFURL, &isTranslocated, &checkError)
        if let checkError {
            AppLogger.log("[MoveToApplications] SecTranslocateIsTranslocatedURL error: \(checkError.takeRetainedValue())")
        }
        guard checkOK, isTranslocated.boolValue else {
            return .notTranslocated
        }

        var originalError: Unmanaged<CFError>?
        guard let result = createOriginalFn(url as CFURL, &originalError) else {
            if let originalError {
                AppLogger.log("[MoveToApplications] SecTranslocateCreateOriginalPathForURL error: \(originalError.takeRetainedValue())")
            }
            return .unknown
        }
        return .translocated(original: result.takeRetainedValue() as URL)
    }
}
