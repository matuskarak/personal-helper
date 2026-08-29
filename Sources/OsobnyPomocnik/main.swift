import AppKit

AppLogger.installCrashHandlers()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no Dock icon
app.mainMenu = .osobnyPomocnikMenu()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
