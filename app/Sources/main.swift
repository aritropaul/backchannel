import AppKit

let app = NSApplication.shared
// Before anything reads settings or opens a database: bring over WA's data once.
Migration.run()
Migration.rewritePaths()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
