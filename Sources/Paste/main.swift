import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// .accessory：只出现在菜单栏，不进 Dock、不进 Cmd+Tab
app.setActivationPolicy(.accessory)
app.run()
